#!/usr/bin/env node
'use strict';
const configLib = require('../scripts/tdd-guardian/lib/config');
const lanes = require('../scripts/tdd-guardian/lib/lanes');
const {freshness} = require('./strict');
const cwd = process.cwd();
const loaded = configLib.load(cwd);
if (!loaded.exists || loaded.errors.length || !loaded.config.enabled) {
  console.error('Missing, invalid or disabled TDD Guardian configuration');
  process.exitCode = 1;
} else {
  const state = lanes.loadState(cwd);
  console.log(JSON.stringify(Object.fromEntries(['commit','push'].map(action =>
    [action, freshness(loaded.config, state, action, cwd)])), null, 2));
}
