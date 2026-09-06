# Changelog

## Unreleased

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
