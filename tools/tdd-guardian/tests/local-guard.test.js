'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync,execFileSync} = require('node:child_process');
const plugin = path.resolve(__dirname,'..');
const lanes = require('../scripts/tdd-guardian/lib/lanes');
const configLib = require('../scripts/tdd-guardian/lib/config');
const gate = path.join(plugin,'local/gate.js');
const runEnv = {...process.env,GIT_CONFIG_GLOBAL:'/dev/null',GIT_CONFIG_NOSYSTEM:'1',GIT_OPTIONAL_LOCKS:'0'};
delete runEnv.NODE_TEST_CONTEXT;
function fixture() {
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'tddg-local-'));
  const git=(...args)=>execFileSync('/usr/bin/git',['--no-optional-locks',...args],{cwd:dir,env:runEnv,stdio:'pipe'});
  git('init','-q','--initial-branch=main');
  fs.writeFileSync(path.join(dir,'value.js'),'module.exports = 42;\n');
  fs.writeFileSync(path.join(dir,'value.test.js'),`const test=require('node:test');const assert=require('node:assert/strict');const fs=require('node:fs');\ntest('answer',()=>{if(process.env.TDD_PROBE_MUTATE==='1')fs.appendFileSync('value.js','// edited during run\\n');assert.equal(require('./value.js'),42)});\ntest('controlled failure',()=>assert.equal(process.env.TDD_PROBE_FAIL || '0','0'));\n`);
  git('add','.');
  git('-c','user.name=TDD Fixture','-c','user.email=tdd@example.invalid','-c','commit.gpgsign=false','-c','core.hooksPath=/dev/null','commit','-q','-m','fixture');
  const book=path.join(dir,'.claude/tdd-guardian'); fs.mkdirSync(book,{recursive:true});
  const config={schemaVersion:2,enabled:true,blockCommitWithoutFreshGate:true,staleGateAction:'deny',gateFreshnessMinutes:120,smartStaleness:true,lanes:[{name:'unit',command:'node --test value.test.js',coverage:'none',gateOn:['commit'],timeoutMs:10000}],coverageThresholds:{lines:0,functions:0,branches:0,statements:0}};
  fs.writeFileSync(path.join(book,'config.json'),JSON.stringify(config));
  return {dir,book,git,config};
}
function run(f,extraEnv={}) {
  // The baseline is the existing upstream gate path. Once the local runner is
  // supplied, exercise its public CLI; no test expectation changes between them.
  if(fs.existsSync(gate)) {
    const r=spawnSync(process.execPath,[gate,'commit','--cwd',f.dir],{env:{...runEnv,...extraEnv},encoding:'utf8',timeout:30000});
    return {ok:r.status===0,stdout:r.stdout,stderr:r.stderr,status:r.status};
  }
  const context=process.env.NODE_TEST_CONTEXT;delete process.env.NODE_TEST_CONTEXT;
  let result;try{result=lanes.runLane(configLib.load(f.dir).config.lanes[0],f.dir);}finally{if(context!==undefined)process.env.NODE_TEST_CONTEXT=context;}
  const state=lanes.loadState(f.dir);
  lanes.recordLaneResult(state,'unit',result,lanes.headSha(f.dir));lanes.saveState(f.dir,state);
  return result;
}
function decision(f,command='git --no-optional-locks commit -m probe') {
  const def=JSON.parse(fs.readFileSync(path.join(plugin,'codex/hooks.json'),'utf8'));
  const hook=def.hooks.PreToolUse[0].hooks[0].command.replaceAll('${PLUGIN_ROOT}',plugin);
  const r=spawnSync(hook,{shell:true,cwd:f.dir,env:runEnv,input:JSON.stringify({tool_name:'Bash',tool_input:{command},cwd:f.dir}),encoding:'utf8',timeout:15000});
  assert.equal(r.status,0,r.stderr);
  const out=r.stdout.trim()?JSON.parse(r.stdout):{};
  return out.hookSpecificOutput?.permissionDecision || 'no-objection';
}
test('local: no passed tests denies commit',()=>assert.equal(decision(fixture()),'deny'));
test('local: actual green tests permit the tested tree even when it is dirty',()=>{
  const f=fixture();fs.appendFileSync(path.join(f.dir,'value.js'),'// pending change\n');
  assert.equal(run(f).ok,true);assert.equal(decision(f),'no-objection');
});
test('local: source changes immediately invalidate a recent green',()=>{
  const f=fixture();assert.equal(run(f).ok,true);
  fs.writeFileSync(path.join(f.dir,'value.js'),'module.exports = 99;\n');
  assert.equal(decision(f),'deny');
});
test('local: source content changes with unchanged size and mtime invalidate green',()=>{
  const f=fixture();assert.equal(run(f).ok,true);
  const p=path.join(f.dir,'value.js'),s=fs.statSync(p);
  fs.writeFileSync(p,'module.exports = 99;\n');fs.utimesSync(p,s.atime,s.mtime);
  assert.equal(decision(f),'deny');
});
test('local: a failed rerun revokes a previous pass',()=>{
  const f=fixture();assert.equal(run(f).ok,true);
  if(!fs.existsSync(gate)) {
    // Run a genuine failing test with the environment, not a fabricated result.
    process.env.TDD_PROBE_FAIL='1';try { assert.equal(run(f).ok,false); }finally{delete process.env.TDD_PROBE_FAIL;}
  } else assert.equal(run(f,{TDD_PROBE_FAIL:'1'}).ok,false);
  assert.equal(decision(f),'deny');
});
test('local: a source edit during an otherwise passing suite cannot earn green',()=>{
  const f=fixture();
  if(!fs.existsSync(gate)) {
    process.env.TDD_PROBE_MUTATE='1';try{assert.equal(run(f).ok,false);}finally{delete process.env.TDD_PROBE_MUTATE;}
  } else assert.equal(run(f,{TDD_PROBE_MUTATE:'1'}).ok,false);
  assert.equal(decision(f),'deny');
});
test('local: adding a new source file invalidates green',()=>{
  const f=fixture();assert.equal(run(f).ok,true);fs.writeFileSync(path.join(f.dir,'new.js'),'module.exports=1;\n');assert.equal(decision(f),'deny');
});
test('local: deleting source invalidates green',()=>{
  const f=fixture();assert.equal(run(f).ok,true);fs.unlinkSync(path.join(f.dir,'value.js'));assert.equal(decision(f),'deny');
});
test('local: documentation and bookkeeping changes do not invalidate green',()=>{
  const f=fixture();assert.equal(run(f).ok,true);fs.writeFileSync(path.join(f.dir,'NOTES.md'),'notes');fs.writeFileSync(path.join(f.book,'notes.json'),'{}');assert.equal(decision(f),'no-objection');
});
test('local: test command configuration changes invalidate green',()=>{
  const f=fixture();assert.equal(run(f).ok,true);f.config.lanes[0].command='true';fs.writeFileSync(path.join(f.book,'config.json'),JSON.stringify(f.config));assert.equal(decision(f),'deny');
});
test('local: legacy timestamp-only state cannot bypass the strict guard',()=>{
  const f=fixture();const s=lanes.emptyState();s.lanes.unit={last_passed_at:new Date().toISOString(),last_result:'passed',last_head_sha:lanes.headSha(f.dir)};lanes.saveState(f.dir,s);assert.equal(decision(f),'deny');
});
test('local: state changes cannot affect the fingerprint and tests can refresh again',()=>{
  const f=fixture();assert.equal(run(f).ok,true);assert.equal(run(f).ok,true);assert.equal(decision(f),'no-objection');
});
test('local: protected file contents are never opened by fingerprinting',()=>{
  const f=fixture();const strict=require('../local/strict');
  const secret=path.join(f.dir,'.env');fs.writeFileSync(secret,'SYNTHETIC_TEST_FIXTURE=one\n');
  const original=fs.readFileSync;let attempts=0;
  fs.readFileSync=function(file,...args){if(path.resolve(String(file))===secret){attempts++;throw Error('must not open protected contents');}return original.call(this,file,...args);};
  try { assert.match(strict.fingerprint(f.dir),/^[a-f0-9]{64}$/);assert.equal(attempts,0); }
  finally { fs.readFileSync=original; }
});
test('local: a symlink to an external file is fingerprinted without opening its target',()=>{
  const f=fixture();assert.equal(run(f).ok,true);
  const external=path.join(os.tmpdir(),'tddg-external-'+path.basename(f.dir)+'.js');
  fs.writeFileSync(external,'module.exports=42;\n');
  fs.unlinkSync(path.join(f.dir,'value.js'));fs.symlinkSync(external,path.join(f.dir,'value.js'));
  assert.equal(decision(f),'deny');
});
