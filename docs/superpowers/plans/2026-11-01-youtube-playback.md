# YouTube Playback Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans inline. The user prohibits delegation.

**Goal:** Open a public YouTube video in VideoTool with native controls, stable stars and resume.

**Architecture:** A pure YouTube request/result model and bounded asynchronous
yt-dlp resolver feed per-file mpv loading. A compact AppKit sheet owns resolution;
the player keeps canonical identity separate from ephemeral playback targets.

**Tech Stack:** Swift, AppKit, MPVKit, installed yt-dlp/Deno, Swift Testing.

**Spec:** ../specs/2026-11-01-youtube-playback-design.md

## Global Constraints

- Public finite on-demand videos; no browser/account integration or dependency installation.
- Keep local playback, user data, unrelated `.codex-suite/` and installed backups intact.
- Chinese L strings with English/Japanese translations; test data under AppData/TestTemp.
- Git commands use --no-optional-locks. Regenerate Xcode files with scripts/regen.sh only.
- Work in the user's selected checkout; execute and review inline, no other agents.

## Review Focus

- Lookalike URL hosts, credentials, option injection and malformed media URLs.
- Cancellation/timeouts while resolver output or child processes are still pending.
- Old resolution/fileLoaded events arriving after another open or shutdown.
- Expiring media addresses must not become durable resume/star identity.
- Separate audio, loading failures and options leaking into subsequent local playback.

### Task 1: Request, resolver and identity

**Files:** new Playback/YouTubeVideo.swift, Playback/YouTubeResolver.swift;
Tests/VideoToolTests/YouTubeVideoTests.swift, YouTubeResolverTests.swift.

**Interfaces:** YouTubeVideo.init(_ text: String) throws, id, url, start;
ResolvedYouTubeVideo.decode(data:request:) throws, videoURL, audioURL, headers;
YouTubeResolving.resolve(_:completion:) and cancel().

- [x] Write tests for URL variants, rejected hosts/schemes, timestamps, identity,
  JSON formats/headers/live rejection and bounded, isolated process invocation.
- [x] Run tests red before adding production types.
- [x] Implement pure parser and cancellable resolver with injected process runner.
- [x] Run targeted tests green; record actual live metadata probe outcome.

### Task 2: Network playback and durable identity

**Files:** MPVEngine.swift, PlayerWindowController.swift, ResumePositionStore.swift,
BookmarkController.swift; YouTubePlaybackTests.swift and PlayerWiringTests.swift.

- [x] Write failing tests for canonical resume, remote star identity without file IO,
  separate A/V and per-file options, successful network-to-local transition.
- [x] Implement file-scoped stream load, stable persistence and local-only feature guards.
- [x] Run targeted tests green against real mpv; verify errors and stale open events.

### Task 3: Entry sheet and user feedback

**Files:** new Player/NetworkVideoSheet.swift; AppDelegate.swift and translations;
NetworkVideoSheetTests.swift, UISnapshotTests.swift.

- [x] Write failing action tests for invalid input, cancel, retry, late completions,
  and opening a local file while resolution is pending.
- [x] Implement menu entry/sheet, progress/error text and player handoff.
- [x] Run native event checks, localization and snapshot review.

### Task 4: Review, verification and delivery

- [x] Review changed files and direct callers using Codex Suite in this session.
- [x] Fix substantiated findings with red/green regression tests.
- [x] Stage newly added files; run all configured Guardian commit lanes.
- [x] Exercise a public YouTube video if reachable; clearly record any live limitation.
- [x] Build Release, update dated Chinese CHANGELOG and README instructions.
- Publication gate: run both secret scanners before commit/push, then verify remote HEAD. The completion response records the publication result.
- [x] Verify/install Release via normal quit, backup and restart where acceptance permits.

## Execution record

- Initial checkout: main, no tracked changes; existing untracked `.codex-suite/` preserved.
- Installed yt-dlp and Deno found at standard Homebrew paths; no components installed.
- Initial sandbox metadata probe failed with network/DNS error. An alternate public
  YouTube Developers example resolved outside the sandbox without credentials.
- Actual red/green findings: URL-only `/watch` resume-key collision; explicit
  timestamp losing to stored resume; invalid control characters in headers; raw
  media paths in diagnostics; incorrect nested HTTP header escaping (live HTTP 400);
  local-only clip keyboard action; missing immediate load-failure feedback;
  implicit TLS settings; uncapped fallback format; timestamp with unknown duration.
- Successful live acceptance: YouTube Developers video `M7lc1UVf-VE`, separate
  video/audio decoding, TLS verification, 2×, seek and pause. Final combined
  acceptance run: 22 tests in 4 suites passed. Public access is sampled, not universal.
- Compact sheet snapshot reviewed; 375 translation keys pass EN/JA checks.
- Executor and Codex Suite review: current session, no delegation/paid models.

- Final offline gate: core 68, unit 553 (3 skips), integration 73, prototype and Guardian 325 passed; commit/push readiness true. Release built, signed and installed with a recoverable backup; installed executable matches Release. No new DMG. Live validation was muted decoding; installed manual gestures and speaker listening remain unverified.
