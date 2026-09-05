# Agent status interface v1

This is the stable, provider-neutral extension point for RehireBar.
An Agent publishes a small JSON snapshot; it does not need to link AppKit, call a
private Touch Bar API, or imitate Codex Desktop.

## Where to publish

Write one file per provider to:

```text
~/Library/Application Support/RehireBar/agents/<provider>.json
```

Replace the file atomically: write a sibling temporary file, then rename it over
the old file. The application reads every `.json` file independently. One invalid
document is ignored without hiding other providers or Codex tasks.

Each document must be a regular file no larger than 1 MiB (1,048,576 bytes).
Symbolic links, named pipes, and other special files are ignored. Do not symlink
the provider directory. Equal-time tasks are ordered by their complete identity
so repeated reads do not shuffle the cards.

Read the [JSON Schema](agent-status-v1.schema.json) for required fields and types,
the [example document](examples/minimal-agent-status.json) for the file shape,
and the [Swift model](../../Sources/AgentStatusCore/AgentStatusDocument.swift) for
the implementation contract. Timestamps are ISO 8601 strings. The example's task,
model, and dates are fictional; they are not live status or defaults to publish.

## Minimal document

```json
{
  "schemaVersion": 1,
  "providerID": "acme-agent",
  "observedAt": "2026-09-04T08:30:00Z",
  "tasks": [
    {
      "identity": { "scopeID": "macbook", "taskID": "task-42" },
      "title": "Refactor payments",
      "location": "local",
      "state": "working",
      "stateObservedAt": "2026-09-04T08:29:58Z",
      "activeSince": "2026-09-04T08:27:10Z",
      "model": "future-model",
      "effort": "high",
      "isCompactingContext": false,
      "openURL": "https://agent.example/tasks/task-42"
    }
  ]
}
```

## Identity and multi-Agent rules

The complete identity is `(providerID, scopeID, taskID)`:

- `providerID` is a stable reverse-DNS name or short ecosystem identifier.
- `scopeID` is the stable machine, workspace, account, team, or runtime namespace.
- `taskID` is stable for the life of the task.

Titles and project names are presentation data, never identity. Two Agents may use
the same task ID safely because their provider IDs differ. One provider may publish
many concurrent tasks, including tasks from multiple scopes.

Optional `projectID` identifies a project within the provider and scope. It is used
only to prioritize projects in the monitor; every task still has its own identity
and card. Omit it when unavailable. `projectName` remains a display label and does
not group unrelated projects with the same name.

Optional `lastActivityAt` is the time of meaningful task activity, such as a new
turn, task progress, or completion. Keep it unchanged for heartbeats, polling,
metadata-only updates, and focus changes. `observedAt` and `stateObservedAt` confirm
freshness and must not substitute for activity. If `lastActivityAt` is absent, a
reported `activeSince` may supply a known start time; otherwise activity stays absent.

Monitoring order is `working`, `waiting`, `error`, `syncing`, then idle/unknown.
Within a state, active projects come first, followed by project and task activity
in descending time order. Full task identity only breaks ties; this never collapses
the tasks of one project into a single entry.

## State contract

Allowed states are `working`, `syncing`, `waiting`, `error`, `idle`, and `unknown`.

- `working`: productive execution is confirmed now.
- `syncing`: transport or state reconciliation is in progress; do not use this as
  a generic remote marker.
- `waiting`: the user or an external decision must act.
- `error`: execution ended or is blocked by a confirmed error.
- `idle`: no turn is executing and synchronization is complete.
- `unknown`: the provider cannot currently establish the state.

`stateObservedAt` records when the source last confirmed the state. If omitted,
the document `observedAt` is used. Active claims (`working`, `syncing`, `waiting`)
degrade to `unknown` once that observation is more than 30 seconds old. A fresh
source observation may confirm an unchanged state; merely rewriting an old
snapshot must not advance its evidence timestamps. Keep `activeSince` tied to
the start of execution rather than resetting it on each observation. This prevents
a crashed or disconnected provider from leaving a false running state.
Publishing an empty `tasks` array removes that provider's cards. The coordinator
also expires retained active claims during collector failures, so a missing file
or interrupted read cannot keep a stale `RUN` or compaction animation alive.

## Optional information

Omit a field when it is unknown. In particular, do not send zero as a substitute
for missing context usage.

- Context appears only when both `usedTokens >= 0` and `contextWindow > 0` exist.
- `model` and `effort` carry the original source values. Their display labels are
  controlled separately by the [model display interface](MODEL-DISPLAY-INTERFACE.md)
  and its editable mapping tables; do not replace source IDs with abbreviations.
  `serviceTier` values
  `fast` and `priority` display the fast-mode bolt.
- Set `isCompactingContext` only while compaction is actively running.
- Use `location: remote` and a short `locationLabel` only when location matters.
  The UI adds the common `REMOTE` tag; raw route IDs should not be labels.
- `openURL` is optional. When present, the app opens it only after a deliberate
  task-card tap. The provider is responsible for choosing a safe, stable URL.

## Compatibility

Additive fields require no schema-version change. A breaking semantic or structural
change requires a new `schemaVersion`; the app ignores versions it does not support.
The model display policy owns model/effort abbreviation. The UI is width-adaptive
and owns color, animation, and omission rules. Providers must not pre-format
strings for a particular Touch Bar width.
