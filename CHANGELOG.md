# Changelog

## Unreleased

## 0.5.5 — 2026-09-06

- Start collapsed and open only from the Control Strip icon or **Show Touch Bar**.
  Background refresh, app activation, approval layout changes, and wake events
  never request presentation. Continue monitoring and expiring stale task states.
- Limit presentation recovery to one immediate composition-reset retry per user
  action; remove the background presentation watchdog and app-relaunch escalation.
- Require a fresh version-scoped worktree for each update or debug task, followed
  by validation and a focused merge into `main` with concise Git history.
- Thanks to [Empsunrise](https://github.com/Empsunrise) for inspiring this behavior
  through [Codex Status Touch Bar PR #2](https://github.com/binlabongbom/codex-status-touch-bar/pull/2).

## 0.5.4 — 2026-09-06

- Show the installed marketing version and build in the menu and through
  `--version`; use the same bundle version in Codex client initialization.
- Add **Check for Updates…** with Sparkle 2.9.6. Users confirm installation;
  background checking, automatic installation, and system profiling are off by default.
- Verify signed update feeds and archives before installation; package the updater
  framework and its notices, and generate separate signed ARM/Intel update feeds.
- Add an isolated updater test covering install/relaunch, no update, downgrade
  prevention, and rejection of modified feeds or archives.
- Normalize all bundle permissions after code signing, including generated
  signature files, so packages built with a private umask remain readable.

## 0.5.3 — 2026-09-06

- Add a persistent **Task order → Waiting first** option that brings waiting and
  failed tasks ahead of running tasks. The default remains running first; changing
  order preserves task identities and does not reopen a collapsed Touch Bar.
- Add `RehireBar doctor --json` for bounded, read-only environment diagnostics:
  actual desktop/CLI versions, Touch Bar detection, registered task navigation,
  data-source presence, and source-specific cache freshness. Readiness is reported
  separately from untested runtime behavior.
- Document the current ChatGPT/Codex host identity, integration boundaries, and
  hardware acceptance gaps; add a structured compatibility issue template.

## 0.5.2 — 2026-09-06

First public release of RehireBar.

- Prioritize running tasks and active/recent projects using source activity timestamps; polling and focus no longer stand in for activity. Add optional `projectID` and `lastActivityAt` to the Agent v1 contract.
- Build and test directly from `release/`, verify the launched bundle's exact path/PID, and capture private live ordering diagnostics. Make this the default local Run workflow.
- Fix independent task monitoring: preserve multiple tasks in one project, rotate runtime reads beyond the first screen, keep inactive focus changes from displacing active cards, and reject older field/state overrides.
- Separate Apple silicon and Intel release archives, architecture checks, and a repeatable dual-architecture packaging command.

- Versioned, editable model display rules and mapping tables with provider-specific overrides, safe local reload, and `GPT6-astra` / `gpt-6-astra` displayed as `6.0A`.
- Extension-development links to the interface contract, JSON Schema, examples, architecture, and contribution guide.
- RehireBar: a native Touch Bar status app for Codex and other AI agents.
- Local and remote task cards, context, model, quota, navigation, and explicit approvals.
- Independent monochrome menu-bar symbol and dimensional application icon.
- Bounded Agent JSON reads, expiring status evidence, and resilient refresh coordination.
- Dedicated RehireBar application identity, storage, executable, and environment settings.
- Source-build packaging with signature and embedded-path verification.
