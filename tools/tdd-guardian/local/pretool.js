#!/usr/bin/env node
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const configLib = require('../scripts/tdd-guardian/lib/config');
const lanes = require('../scripts/tdd-guardian/lib/lanes');
const strict = require('./strict');
function deny(reason) {
  console.log(JSON.stringify({hookSpecificOutput:{hookEventName:'PreToolUse',permissionDecision:'deny',permissionDecisionReason:reason}}));
}
try {
  const event = JSON.parse(fs.readFileSync(0,'utf8'));
  if (event.tool_name === 'Bash') {
    const action = lanes.classifyCommand(String(event.tool_input?.command || ''));
    if (action) {
      const workdir = event.tool_input?.workdir || event.cwd || process.cwd();
      const cwd = strict.git(path.resolve(workdir), ['rev-parse','--show-toplevel']).trim();
      const loaded = configLib.load(cwd);
      if (loaded.exists && loaded.config?.enabled !== false && loaded.config?.blockCommitWithoutFreshGate !== false) {
        if (loaded.errors.length) deny('Invalid TDD Guardian config; no gate can be verified.');
        else {
          const result = strict.freshness(loaded.config, lanes.loadState(cwd), action, cwd);
          if (!result.ok) deny(result.reasons.join('\n') + '\nRun: node tools/tdd-guardian/local/gate.js ' + action);
        }
      }
    }
  }
} catch (e) { deny('TDD Guardian could not verify this action: ' + e.message); }
