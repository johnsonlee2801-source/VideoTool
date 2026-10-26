'use strict';
// Local enforcement adapter. The upstream engine remains responsible for running
// lanes; its timestamp-only freshness check is not used by the installed hook.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const {spawnSync} = require('node:child_process');
const configLib = require('../scripts/tdd-guardian/lib/config');
const lanes = require('../scripts/tdd-guardian/lib/lanes');
const exec = require('../scripts/tdd-guardian/lib/exec');

function git(cwd, args) {
  const r = spawnSync('git', ['--no-optional-locks', ...args], {
    cwd, encoding: 'utf8', timeout: 15000, maxBuffer: 32 * 1024 * 1024,
    env: {...process.env, GIT_OPTIONAL_LOCKS: '0'},
  });
  if (r.status !== 0) throw new Error('Cannot inspect the Git working tree');
  return r.stdout;
}

// Never open authentication or secret files, even if accidentally tracked.
// Their metadata still invalidates the gate when they change.
function protectedFile(name) {
  return /(^|\/)(\.env(?:\.[^/]*)?|(?:auth|authentication|accounts?|tokens?|credentials?|secrets?|keychain)(?:[.-][^/]*)?|\.npmrc|\.netrc|id_(?:rsa|ed25519)|[^/]*\.(?:pem|key|p12|pfx))$/i.test(name)
    || /(^|\/)\.(?:ssh|aws|gnupg)(\/|$)/.test(name);
}

function fingerprint(cwd) {
  const root = fs.realpathSync(cwd);
  const names = new Set(git(root, ['ls-files', '--cached', '--others', '--exclude-standard', '-z']).split('\0').filter(Boolean));
  // A config change can change what was tested; state and receipts are outputs.
  names.add('.claude/tdd-guardian/config.json');
  const hash = crypto.createHash('sha256');
  for (const name of [...names].sort()) {
    if (!lanes.isSourceFile(name) && name !== '.claude/tdd-guardian/config.json') continue;
    const file = path.resolve(root, name);
    if (!file.startsWith(root + path.sep)) throw new Error('Source path escapes the repository');
    hash.update(JSON.stringify(name) + '\0');
    let stat;
    try { stat = fs.lstatSync(file); }
    catch (e) { if (e.code === 'ENOENT') { hash.update('missing\0'); continue; } throw e; }
    const parent = fs.realpathSync(path.dirname(file));
    if (parent !== root && !parent.startsWith(root + path.sep)) throw new Error('Source parent escapes the repository');
    hash.update(String(stat.mode) + '\0');
    if (stat.isSymbolicLink()) hash.update('symlink:' + fs.readlinkSync(file));
    else if (protectedFile(name)) hash.update(JSON.stringify([stat.size, stat.mtimeMs, stat.ctimeMs]));
    else if (stat.isFile()) hash.update(fs.readFileSync(file));
    else throw new Error('Cannot fingerprint a non-file source entry');
    hash.update('\0');
  }
  return hash.digest('hex');
}

function freshness(config, state, action, cwd) {
  const required = lanes.lanesRequiredFor(config, action);
  let current;
  try { current = fingerprint(cwd); }
  catch (e) { return {ok: false, reasons: ['Source fingerprint unavailable: ' + e.message]}; }
  const reasons = [];
  for (const lane of required) {
    const entry = state.lanes?.[lane.name];
    if (!entry || entry.last_result !== 'passed') reasons.push(lane.name + ': latest run did not pass');
    else if (!entry.source_fingerprint) reasons.push(lane.name + ': no tested source fingerprint; rerun the gate');
    else if (entry.source_fingerprint !== current) reasons.push(lane.name + ': source or test configuration changed');
    else {
      const stamp = Date.parse(entry.last_passed_at);
      const age = Date.now() - stamp;
      if (!Number.isFinite(stamp) || age < 0) reasons.push(lane.name + ': invalid pass timestamp');
      else if (config.smartStaleness === false && age > config.gateFreshnessMinutes * 60000) reasons.push(lane.name + ': gate expired');
    }
  }
  if (!required.length) reasons.push('No lane gates this action');
  return {ok: !reasons.length, reasons};
}

function record(cwd, lane, result, before, after) {
  const state = lanes.loadState(cwd);
  lanes.recordLaneResult(state, lane.name, result, lanes.headSha(cwd));
  const entry = state.lanes[lane.name];
  entry.source_fingerprint = result.ok && before && before === after ? after : null;
  // Keep the old pass timestamp for history, but never use it to forgive red.
  lanes.saveState(cwd, state);
  return state;
}

function runGate(cwd, target, log = console.log) {
  const loaded = configLib.load(cwd);
  if (!loaded.exists || loaded.errors.length || !loaded.config.enabled) throw new Error('Missing, invalid or disabled TDD Guardian configuration');
  const config = loaded.config;
  const triggers = ['commit', 'push', 'taskCompleted', 'manual'];
  const named = config.lanes.find(l => l.name === target);
  const selected = named ? [named] : triggers.includes(target) ? lanes.lanesForTrigger(config, target) : [];
  if (!selected.length) throw new Error('No configured lanes match the gate target');
  // Reject unsupported policy rather than report a lane-only pass as a full gate.
  if (config.requireMutation || config.criticalPaths?.some(p => p.requireMutation)
      || config.lanes.some(l => l.coverage === 'include')
      || Object.values(config.coverageThresholds).some(n => n > 0)) {
    throw new Error('This project adapter runs lane gates only. Coverage/mutation policy needs an explicit adapter before enabling it; no gate state was refreshed.');
  }
  if (config.preflightCommand) {
    const pre = exec.run(config.preflightCommand, cwd);
    if (pre.status !== 'pass') {
      for (const lane of selected) record(cwd, lane, {...pre, ok:false, status:'preflight-failed'}, null, null);
      throw new Error('Preflight failed: ' + pre.stderrTail);
    }
  }
  for (const lane of selected) {
    const before = fingerprint(cwd);
    const result = lanes.runLane(lane, cwd);
    const after = fingerprint(cwd);
    if (result.ok && before !== after) { result.ok = false; result.status = 'source-changed-during-run'; }
    record(cwd, lane, result, before, after);
    log(lanes.describeResult(result));
    if (!result.ok) {
      log(result.stdoutTail); log(result.stderrTail);
      return {ok:false, lane:lane.name, status:result.status};
    }
  }
  return {ok:true, lanes:selected.map(l => l.name)};
}

module.exports = {fingerprint, protectedFile, freshness, runGate, git};
