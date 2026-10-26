'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const exec=require('../scripts/tdd-guardian/lib/exec');
test('local: Swift Testing green summary reports actual tests, not XCTest zero',()=>{
 assert.deepEqual(exec.parseCounts('Executed 0 tests, with 0 failures\n✔ Test run with 68 tests in 3 suites passed after 0.01 seconds.',''),{passed:68,failed:0,skipped:0,total:68});
});
test('local: Swift issues are not mistaken for failed test count',()=>{
 const out='✘ Test "A1" failed after 0.1 seconds with 4 issues.\n✘ Test "A2" failed after 0.1 seconds with 1 issue.\n✘ Test "A3" failed after 0.1 seconds with 2 issues.\n✘ Test "A8" failed after 0.1 seconds with 2 issues.\n✘ Suite X failed after 0.1 seconds.\n✘ Test run with 68 tests in 3 suites failed after 0.1 seconds with 9 issues.';
 assert.deepEqual(exec.parseCounts('',out),{passed:64,failed:4,skipped:0,total:68});
});
test('local: Swift skipped tests are not counted as passes',()=>{
 assert.deepEqual(exec.parseCounts('✘ Test "fails" failed after 0.1 seconds with 1 issue.\n✘ Test "optional" skipped.\n✘ Test run with 5 tests failed after 0.1 seconds with 1 issue.',''),{passed:3,failed:1,skipped:1,total:5});
});
test('local: incomplete failed Swift output does not invent a failed count',()=>{
 assert.equal(exec.parseCounts('✘ Test run with 68 tests in 3 suites failed after 0.1 seconds with 9 issues.',''),null);
});
test('local: Node TAP counts demonstrate assertions really ran',()=>{
 assert.deepEqual(exec.parseCounts('1..2\n# tests 2\n# suites 0\n# pass 1\n# fail 1\n# skipped 0\n',''),{passed:1,failed:1,skipped:0,total:2});
});
test('local: zero discovered tests cannot produce a passing gate',()=>{
 assert.equal(exec.classify(0,'1..0\n# tests 0\n# pass 0\n# fail 0\n',''),'no-tests');
});
test('local: a passing test title containing skipped is not a skipped result',()=>{
 const out='◇ Test "RF7 when translation is skipped the file is original-only" started.\n✔ Test "RF7 when translation is skipped the file is original-only" passed after 0.1 seconds.\n✘ Test "D1" skipped.\n✘ Test "D2" skipped.\n✔ Test run with 481 tests in 112 suites passed after 1.0 seconds.';
 assert.deepEqual(exec.parseCounts(out,''),{passed:479,failed:0,skipped:2,total:481});
});
test('local: real Swift Testing skipped output uses the arrow outcome marker',()=>{
 const fs=require('node:fs'),path=require('node:path');
 const out=fs.readFileSync(path.join(__dirname,'fixtures/swift-skipped.output'),'utf8');
 assert.deepEqual(exec.parseCounts(out,''),{passed:1,failed:0,skipped:2,total:3});
});
test('local: a suite containing only skipped tests is not a passing gate',()=>{
 const out='➜ Test "D1" skipped.\n➜ Test "D2" skipped.\n✔ Test run with 2 tests in 0 suites passed after 0.001 seconds.';
 assert.equal(exec.classify(0,out,''),'no-tests');
});
