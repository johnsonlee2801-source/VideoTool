# VideoTool local adapter

Upstream: xiaolai/tdd-guardian-for-claude, commit recorded in `UPSTREAM.json`.
The ISC copyright and permission notice are retained in `LICENSE`.

Local changes are confined to `local/`, the Codex gate/status entrypoints and hook
registration, local path/inline-role overrides for skills and shared lane guidance,
Swift/Node runner-count parsing, and `tests/local-*.test.js`.
The upstream timestamp-only hook remains in the bundle for provenance but is not
the hook registered by this plugin.

The strict runner records actual lane outcomes and fingerprints Git-visible source
contents before and after each run, including uncommitted/untracked source and the
test configuration. It excludes documentation and Guardian's own runtime evidence.
Authentication/secret files are never opened: only their filesystem metadata is
included if Git lists them. Symlinks are hashed as links, never followed outside
the repository. A failed or interrupted run cannot inherit an earlier pass.

No network service, package installation, model call or Claude account is used by
the execution adapter. The reviewed local shell commands in the project config
are the only commands it launches, in addition to read-only Git inspection.

The adapter currently supports lane-only gates and refuses coverage/mutation
enforcement it cannot establish. The upstream audit skills remain available.
Hooks are guardrails for supported shell invocations, not an OS security boundary.
They do not intercept direct subprocesses inside already-running programs, and
native Codex hook trust is a separate user action. No trust bypass is installed.

The installed project uses `.agents/skills/` links and `.codex/hooks.json` directly;
it does not require a global marketplace registration or cached plugin install.
