# Changelog

## 0.0.1.alpha3 - 2026-07-10

### Bumped

- Runtime dependency `opencode-ruby` pinned to `= 0.0.1.alpha3`, exposing
  the session permission PATCH primitive to Rails host applications while
  leaving reconciliation policy in each host.

## 0.0.1.alpha2 — 2026-05-20

### Changed

- `Opencode::Exchange` now emits `opencode.apply_patch.artifacts_dropped`
  via the new `Opencode::Instrumentation.notify` fire-and-forget API
  (introduced in opencode-ruby v0.0.1.alpha2) instead of
  `.instrument(name, payload) { }` with an empty block. Cleaner read
  at the call site; identical semantics on the wire (same event name,
  same payload).

### Bumped

- Runtime dependency `opencode-ruby` pinned to `= 0.0.1.alpha2` (was
  `= 0.0.1.alpha1`). Versions stay in lockstep during alpha.

## 0.0.1.alpha1 — 2026-05-20

Initial public alpha. Extracted from a production Rails app where these objects shipped as in-tree library code before being carved out into a standalone gem.

**Includes:**

- `Opencode::Session` — AR-coupled, row-level-locked session lifecycle (`ensure!`, `recreate!`, `abort!`)
- `Opencode::Turn` — orchestrator covering send → stream → recover → finalize, with CAS-safe message terminal-state transitions
- `Opencode::Exchange` — domain object over a turn's message array; emits `opencode.apply_patch.artifacts_dropped` when post-write file content is unavailable
- `Opencode::Artifact` — value-object (filename + content + content_type + trust metadata), idempotent attach
- `Opencode::MessageArtifacts` — ActiveStorage-aware artifact attachment pipeline with transform support
- `Opencode::Sandbox` — disk-backed sandbox reader, returns `Artifact` list
- `Opencode::SandboxFile` — single-file value object (pathname → bytes/content-type)
- `Opencode::Transform` — base class for content-rewriting transforms
- `Opencode::Impostor` — ActiveStorage download/upload round-trip helper
- `Opencode::UploadedFilesPrompt` — user-prompt prefix builder listing uploaded files, sandbox-path inverted (injection-based, no `Opencode::Permissions` reference)
- `Opencode::ToolDisplay` — view-model for tool-call hashes (Turbo Stream-friendly)
- `Opencode::ErrorReporter` — pluggable adapter mirroring the `Opencode::Instrumentation` pattern

**Runtime dependencies:**

- `opencode-ruby ~> 0.0.1.alpha1` (wire client + Reply state machine)
- `activerecord >= 7.1, < 9.0`
- `activestorage >= 7.1, < 9.0`
- `activesupport >= 7.1, < 9.0`

**Known limitations (alpha):**

- Apply-patch tool's post-write file content is not extracted (wire-format limitation in OpenCode v1.15+); affected files surface via the `opencode.apply_patch.artifacts_dropped` instrumentation event. Future work: optional sandbox-read fallback path.
- Smoke tests only inside the gem. Behavioral coverage currently lives in the host app that produced this code. A standalone gem-side test suite using Combustion is open work.
- No generator (`rails g opencode:install`) yet.
- No Rails Engine integration — `require "opencode-rails"` is sufficient.
