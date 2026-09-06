# RehireBar: AI contributor guide

Read `docs/integrations/AGENT-STATUS-INTERFACE.md` before adding an Agent source.
Read `docs/integrations/MODEL-DISPLAY-INTERFACE.md` before changing model labels;
edit the data in `Resources/ModelDisplay.json` rather than adding UI mappings.
Do not put provider-specific parsing, state names, or navigation rules in the Touch
Bar UI. Providers publish the shared status document; the application maps that
document to its presentation-neutral session model; the presenter only lays out
available facts.

## Architectural boundaries

- `Sources/AgentStatusCore/` owns public, Foundation-only data contracts.
- `Sources/RehireBar/` owns collection, state resolution, AppKit, and lifecycle.
- Provider identity is always `(providerID, scopeID, taskID)`. Never key a task by
  title, project, or task ID alone.
- Monitor tasks independently of foreground focus. Default to running tasks first,
  then waiting, error, syncing, and idle/unknown tasks. The optional waiting-first
  preference elevates waiting and error tasks ahead of running tasks. Resolve this
  order in the coordinator before publishing or presenting. Within a state,
  prioritize active/recent projects and recent activity; identity only breaks ties.
- Keep `lastActivityAt` separate from `observedAt`. Polling, heartbeats, and focus
  changes must not manufacture task activity or replace another task's state.
- Project identity scopes ordering metadata only. Never collapse a project's tasks
  into one card, or group projects by display name alone.
- Unknown data stays absent. Never manufacture token counts, model names, runtime
  states, timestamps, or remote labels.
- Diagnostic readiness is not runtime acceptance. A registered URL handler or an
  existing IPC socket does not prove that a task opens or a reply is delivered.
- Active state claims expire when their source stops publishing. Prefer `unknown`
  over a stale `working`, `syncing`, or `waiting` state.
- A task URL is opened only after the user taps that task card.
- Start collapsed. Only an explicit Control Strip or application-menu action may
  open the Touch Bar. Background refresh, activation, approvals, and wake events
  update content without presenting. Keep any presentation retry synchronous and
  bounded to that action; state-expiry checks must never restore or relaunch UI.
- Application updates use Sparkle with signed feeds and archives. Keep update
  checks separate from status polling; defaults must require a user-initiated
  check and installation. Never commit private update-signing seeds.

## Local development and Git history

- Before every update or debugging task, create a fresh version-scoped Git
  worktree and a focused `codex/<version>-<topic>` branch from current `main`.
  Inspect dirty worktrees first and preserve existing work; never develop directly
  on `main` or silently carry unrelated changes into the new worktree.
- Validate in that worktree, then integrate through a merge into `main`.
  Prefer one coherent commit and a fast-forward merge; squash temporary fixups
  before integration when needed. Do not rewrite published history.
- Keep commits focused and reviewable. Exclude generated artifacts and private
  diagnostics. Pushing and publishing require the user's requested scope.

## Required validation

Run these commands after a change:

```bash
swift test
swift build -c release
bash scripts/build-app.sh
bash scripts/verify-app.sh
```

Do not commit generated `dist/`, `.build/`, raw logs, or private screenshots.

For local release acceptance, run `bash scripts/test-release.sh --build`. It
verifies the ZIP, runs its extracted app under `release/test/`, and records the
exact process path plus an optional live monitoring snapshot. Test from that
release directory; do not replace Downloads or Applications copies as a test step.
