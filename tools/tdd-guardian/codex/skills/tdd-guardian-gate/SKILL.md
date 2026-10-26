---
name: tdd-guardian-gate
description: Run VideoTool test lanes and record source-bound quality gates before commit or push, or refresh a named lane after implementation.
---

## VideoTool local installation

In VideoTool, resolve `<plugin-root>` as the Git root plus `/tools/tdd-guardian`, including when this skill is listed through a `.agents/skills/` link. This local path rule overrides upstream directory-counting instructions below. Run roles inline unless the user explicitly requests delegation. Existing test lanes are already configured; do not reinitialize them without a setup request. Record gate outcomes only through `<plugin-root>/local/gate.js`; never manufacture or manually copy a passing state. The local gate/status skills override the upstream timestamp-only procedure.


Use the local strict runner for this fork. Resolve `<plugin-root>` three directories above this skill's directory (`codex/skills/tdd-guardian-gate`). Run from the actual project Git root:

```sh
node <plugin-root>/local/gate.js commit
```

Accept only `commit`, `push`, `taskCompleted`, `manual`, or an exact configured lane name. Default to `commit`; pass one argument, never interpolate arbitrary user text into a shell command. `push` also runs commit lanes. A named lane refreshes only itself, so it does not establish that a commit gate passed.

The runner executes the configured real commands, records failures as well as passes, and binds passes to a content fingerprint taken before and after testing. It refuses a pass if source changes during the run. Never write gate state by hand or copy a prior pass. Surface an environment failure as an environment failure; do not change code to chase a missing runner.

This project has lane-only gates: coverage policy and mutation enforcement are currently disabled in its configuration. The local runner refuses to refresh gates if those policies are enabled without an explicit adapter. The separate upstream audit skills remain available for report-only inspection.

Report actual lane/test counts and exit status. On failure, show the relevant failing tests and leave the action blocked. This skill never commits or pushes; a passing gate is not authorization for either.
