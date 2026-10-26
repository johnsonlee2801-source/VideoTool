---
name: tdd-guardian-status
description: Report whether VideoTool's commit and push gates match the current source and latest actual test results, without changing state or running tests.
---

## VideoTool local installation

In VideoTool, resolve `<plugin-root>` as the Git root plus `/tools/tdd-guardian`, including when this skill is listed through a `.agents/skills/` link. This local path rule overrides upstream directory-counting instructions below. Run roles inline unless the user explicitly requests delegation. Existing test lanes are already configured; do not reinitialize them without a setup request. Record gate outcomes only through `<plugin-root>/local/gate.js`; never manufacture or manually copy a passing state. The local gate/status skills override the upstream timestamp-only procedure.


Resolve `<plugin-root>` three directories above this skill's directory (`codex/skills/tdd-guardian-status`). Run from the project Git root:

```sh
node <plugin-root>/local/status.js
```

Report the returned commit/push readiness and reasons. A timestamp-only legacy entry is unverified and must be refreshed; a recent timestamp never overrides a newer failure or a changed source fingerprint. Do not edit state, run suites, or authorize a commit from this read-only command.
