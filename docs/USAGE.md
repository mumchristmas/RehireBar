# Usage

RehireBar runs in the background and exposes one persistent status-strip icon in the native Control Strip.

## Open and collapse the status bar

Tap the status-strip Control Strip icon to present the full status bar. Use the close control on the left to collapse it back to the native Control Strip. Background data refreshes, the 15-second health check, and ordinary Codex foreground activation do not reopen a collapsed bar. The app preserves native brightness, volume, and other macOS controls.

The menu-bar app icon provides **Show Touch Bar** to restore the full bar,
**Task order** to choose monitoring priority, and **Quit RehireBar** to stop the
helper. Quitting removes the app-owned Control Strip item until the app is launched again.

## Read the status groups

- `5H` and `7D` — only the quota windows the account actually provides, with remaining percentage and reset time. A separate yellow dot means the value is stale.
- Session scrubber — local and remote tasks are shown side by side while each card retains its readable minimum width. The common 607pt task area shows three cards, wider layouts can show four, and narrow layouts fall back to two or one; swipe horizontally for the remainder. A lone task expands to the full viewport. Each card shows state and task identity first, then elapsed time, compact model/effort, context progress, and percentage when those values are available.

Quota windows are identified by duration, not response order. If the account plan exposes only one window, the missing window takes no Touch Bar space. A `--` value means the helper could not obtain a current or eligible cached value.

If Codex exposes a 5H window but you prefer to reserve that width for 7D and task cards, set the local display preference and restart the helper:

```bash
defaults write com.bigbom.RehireBar hideFiveHourQuota -bool true
```

Set it to `false` to restore the 5H module. This changes only presentation; collection and caching remain intact.

The session width is recalculated from the physical Touch Bar width, the compact Control Strip configuration, and the visible quota windows. The task item has higher visibility priority than quota items. The helper does not mutate this composition from `NSTouchBarItem.isVisible`: private system-modal items can report false while they are visibly rendered, so that signal would incorrectly remove quota. Under genuine space pressure, AppKit applies the declared priorities.

Task states are deliberately distinct: green `RUN` means fresh runtime evidence confirms productive execution, yellow `WAIT` needs your input, red `ERR` is a task failure, gray `IDLE` is explicitly finished or inactive, orange `COMPACT` is an in-progress context compaction, and blue `SYNC` means Codex Desktop cannot yet confirm fresh state for the card's remote host. `—` means there is not enough current evidence to claim any of those states. Every visible task on a recovering host shows `SYNC`, including tasks last seen as `IDLE`, until Desktop reports that reconnect recovery is complete. Catalog activity alone never produces `RUN` or `IDLE`.

## Refresh immediately

Tap `5H` or `7D`. The app requests a fresh local read immediately and keeps the previous value visible while it waits. Tapping the persistent status-strip icon also refreshes and re-presents the bar.

If nothing changes, the source may have returned the same value or no eligible quota window. The app cannot manufacture a value that Codex has not exposed locally.

## Monitor tasks independently

Tasks in the same project have separate cards, states, models, and context readings.
By default, running tasks appear first, followed by tasks waiting for input, errors,
synchronizing tasks, and idle/unknown tasks. Within each state, active projects
and recently active projects come first, then the most recently active task.
Task identity breaks ties without merging cards.
Swipe horizontally to see the remaining tasks.

In RehireBar 0.5.3 and later, choose **Task order → Waiting first** from the menu-bar
icon to show `WAIT`, then `ERR`, then `RUN`, `SYNC`, and idle/unknown tasks. This
keeps a waiting task on the first screen even when three other tasks are running.
Project and task recency still determine order within a state. The preference is
saved and applies immediately without changing task state, opening a task, or
reopening a collapsed Touch Bar. Select **Running first** to restore the default.
Expired waiting evidence becomes unknown and loses its waiting priority.

Switching to an inactive task in Codex can refresh that task's metadata, but does
not replace a running task's card or scroll the monitoring viewport to the focused
task. Background tasks continue to be sampled independently, including tasks
outside the visible area. When another app becomes frontmost, monitoring continues.

When a remote connection is interrupted, each task on that host shows `SYNC`. A context percentage is retained only while its last owner snapshot remains inside the bounded context freshness window; stale or missing token/context data hides the whole context block rather than showing a made-up value.

The helper first reads focused-primary-window activity metadata from a bounded tail of Codex Desktop's local diagnostic log; it does not inspect prompt or response text. If that source cannot resolve a task, a read-only Accessibility fallback may request access once.

## Open a task in Codex Desktop

Tap any real session card, including a remote-host card whose model or context is unavailable. The helper opens that exact thread in Codex Desktop through its registered `codex://threads/<thread-id>` route. Codex Desktop resolves the thread's local or remote host from its own task catalog.

The compact model/effort text remains display-only. Its [model display policy](integrations/MODEL-DISPLAY-INTERFACE.md) provides editable exact-name, family-suffix, provider-specific, and effort mappings. The shipped rules show `GPT6-astra` and `gpt-6-astra` as `6.0A`; unknown suffixes remain visible after configured prefix removal. A yellow bolt immediately before the model means the task is using fast/priority service. These labels do not change a task's model settings.

## Use CLI display mode without Codex Desktop

The helper starts refreshing at launch. With Codex CLI available, it displays the authoritative account-wide quota from `codex app-server` and reads session, model, and effort from bounded local session logs even when Codex Desktop is absent. If the app-server query is temporarily unavailable, quota fallback records are accepted only for the account-wide `codex` limit; a model-specific bucket cannot replace the 7D value.

Startup is progressive: a minimal local cache is painted first, the focused task is fetched next, then quota and the complete catalog proceed concurrently. Model, context, fast-mode, and compaction details from slower per-thread Desktop runtime requests are added as they arrive. Each runtime request briefly follows the exact task so Codex Desktop can deliver its current in-memory snapshot, then unfollows it. One unavailable source does not hold the entire task area blank.

SSH-host tasks are covered by the normal regression suite. Device-paired Remote Control tasks use the same composite identity and snapshot contract, but remain conditionally supported until a real second-device acceptance run has verified idle, run, wait, compaction, disconnect, and recovery behavior for the installed Desktop version.

This fallback is display-only for live mutations. It does not edit `config.toml` or claim to change an already-running CLI process. Opening a task requires Codex Desktop's registered URL handler, and approval delivery requires a matching confirmation from Codex Desktop.

See [Compatibility](COMPATIBILITY.md) for the tested desktop host and the limits of
CLI-only, external-publisher, Intel, and paired-device support. The optional
[doctor command](DIAGNOSTICS.md) reports local readiness without opening tasks.

## Answer an approval request

When an external agent explicitly registers a decision gate, status metrics temporarily give way to three buttons:

- **Approve** — continue with the proposed action.
- **Reject** — stop or decline the proposed action.
- **Request changes** — return the decision to the source thread for revision.

Unanswered entries expire after 24 hours. The local queue stores at most 32 records. Metrics return after the queue is empty.

## Sleep and wake behavior

After the Mac wakes, the app cancels a request inherited from before sleep, restores its retained Touch Bar, and starts one fresh request. A watchdog checks presentation every 15 seconds. Recovery escalates from re-presentation to an app-only relaunch, limited to once every five minutes.

The app does not keep the physical display awake and does not prevent normal system sleep. User keyboard or mouse activity remains governed by macOS power settings.
