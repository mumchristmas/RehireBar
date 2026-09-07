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

## Scope and authorization

- Follow the user's current task and prior authorization. Resolve routine choices
  within that scope; ask only when missing information materially affects the
  outcome or an action needs authorization not already given.
- Skill guidance supports the task; explicit user instructions take precedence
  over it. If a file requires a pause, cite its path and exact rule and explain
  the missing information or authorization instead of inventing an approval gate.
- Editing and local validation do not authorize pushing, publishing, changing
  installed applications, or sending messages or approval responses to other tasks.
- Report changes, validation, and remaining limits concisely. Distinguish source
  inspection, automated checks, and observed runtime or hardware behavior.

## Development and validation

Follow [the development workflow](CONTRIBUTING.md#development-workflow) for fresh
version-scoped worktrees, local commits and integration into `main`. Keep existing
work intact; do not edit on `main` or rewrite published history.

Use [the validation requirements](CONTRIBUTING.md#validation) for the change type.
Code and packaging changes require the full checks; documentation-only changes
require diff, link, and instruction-consistency checks. Stop after the applicable
checks pass unless new changes or failures justify more testing.

Read [approval integration](docs/APPROVAL-INTEGRATION.md) when changing that path,
and [application updates](docs/UPDATES.md) before changing feeds or signing keys.
