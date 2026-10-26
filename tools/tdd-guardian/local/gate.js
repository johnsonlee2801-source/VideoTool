#!/usr/bin/env node
'use strict';
const {runGate} = require('./strict');
try {
  const args = process.argv.slice(2);
  const target = args.shift() || 'commit';
  let cwd = process.cwd();
  if (args.length) {
    if (args.length !== 2 || args[0] !== '--cwd') throw new Error('Usage: gate.js [commit|push|taskCompleted|manual|lane] [--cwd directory]');
    cwd = args[1];
  }
  const result = runGate(cwd, target);
  process.exitCode = result.ok ? 0 : 1;
} catch (e) { console.error('[tdd-guardian] ' + e.message); process.exitCode = 1; }
