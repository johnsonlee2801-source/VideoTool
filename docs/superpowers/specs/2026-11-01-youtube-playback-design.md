# YouTube in VideoTool

## Intent and decisions

The user chose standalone VideoTool playback of YouTube links, reusing pause,
speed gestures and fullscreen. Implementation and TDD/CC Suite verification
are authorized. This is public, finite on-demand video playback, not a browser
replacement or an account integration.

## Approaches

1. Resolve a YouTube page with yt-dlp and play the resulting streams through the
   existing MPVKit engine (selected): reuses native gestures and rendering; adds
   an external resolver dependency and requires ongoing site compatibility checks.
2. Embed the official YouTube player: website-controlled playback with a separate
   rendering/control surface; does not reuse the existing native engine.
3. Browser extension: changes where the user watches, outside the chosen scope.

## Proposed implementation details

- File > Open Network Video (Shift-Command-O) opens one compact sheet. Paste a
  supported YouTube watch, short, embed or youtu.be URL; normalize to one video ID.
  Ignore playlist/tracking fields; support an explicit start time. No auto-next.
- Resolve asynchronously, with cancel, a bounded timeout and latest-request wins.
  Keep current playback until resolution succeeds. No shell interpolation, user
  configuration, plugins, browser cookies, login files or remote code downloads.
- Reuse installed yt-dlp and Deno from known executable locations. No installation
  or global configuration changes. Explain missing/outdated components in UI.
- Default streams at up to 1080p with separate audio support. Send scoped mpv file
  options, not global settings. Only HTTPS media URLs from expected YouTube CDN
  hosts are accepted from the production resolver. Never persist signed stream
  URLs or print resolver output. Re-resolve on every open.
- Use `youtube:<videoID>` for stars; no remote thumbnail generation in this first
  version. Resume positions use canonical page URL identity separate from file
  paths. Local folders/history/AI subtitles/clipping continue their local scope.
- A visible load failure gives a retryable error; an unresolved or cancelled
  request cannot replace newer local/network playback. Network subtitles, live
  streams, login-restricted media, downloads and browser extensions are out of scope.

## Validation and delivery

Test URL boundaries, identity, timestamps, malformed resolver results, separate
audio, invocation isolation, timeout/cancel/stale results, resume and stars across
link variants, local/network transitions, native sheet actions and snapshots.
Exercise real mpv with deterministic local media and a real public YouTube video
when network access permits. Run project commit gates and scoped current-session
Codex Suite review. Distinguish deterministic checks from live service acceptance.
Publish Chinese change notes with source update; install only a verified Release
using the already authorized normal-quit/backup/restart workflow. No new installer
release or version bump is implied.
