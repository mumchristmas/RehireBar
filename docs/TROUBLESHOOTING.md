# Troubleshooting

## Check this Mac's environment

In RehireBar 0.5.3 and later, run the installed executable with `doctor --json`:

```bash
'/Applications/RehireBar.app/Contents/MacOS/RehireBar' doctor --json
```

This reports desktop and CLI versions, physical Touch Bar detection, source
presence, registered navigation, and cache freshness without opening a task or
sending an approval. It does not certify the live IPC protocol. See
[Diagnostics](DIAGNOSTICS.md) for fields and [Compatibility](COMPATIBILITY.md) for
the acceptance matrix. For release-directory testing, use the exact executable
path recorded by `scripts/test-release.sh`.

## The Touch Bar is blank after sleep

1. Tap the persistent status-strip icon in the Control Strip.
2. Tap `5H` or `7D` once to request an immediate refresh.
3. Wait for one 5-second task refresh cycle. Quota can take up to 30 seconds unless refreshed manually.
4. Confirm the helper is running:

   ```bash
   pgrep -fl RehireBar
   ```

5. Relaunch only this app if needed:

   ```bash
   pkill -x RehireBar || true
   open '/Applications/RehireBar.app'
   ```

The helper intentionally does not restart macOS Touch Bar services.

## `5H` or `7D` shows `N/A`

`N/A` means the current account plan does not expose that quota window. This is expected when Codex returns a seven-day window without a five-hour window, or vice versa. Refreshing cannot create a quota window that the account does not include.

## `5H` or `7D` shows `--`

Possible causes include:

- the local `codex app-server` was unavailable;
- no matching rate-limit event exists in the bounded local session-log tail;
- the last valid observation is more than 15 minutes old;
- Codex moved or changed its local protocol.

Tapping the value starts a request immediately, but it cannot force the upstream Codex service to expose a missing window.

## Tapping refresh appears to do nothing

The old value intentionally stays visible during the request. If Codex returns the same value, the text will not visibly change. If the request fails, the last eligible value remains in place instead of flashing blank.

## No persistent status-strip icon appears

- Confirm the Mac has a physical Touch Bar.
- Confirm macOS is version 15 or later.
- Quit duplicate helper processes and reopen the installed app.
- Check whether a macOS update changed private Touch Bar behavior.

## The app does not start at login

Open **System Settings > General > Login Items**, enable **RehireBar**, then log out and back in. Login items do not inherit shell `PATH`; set `REHIREBAR_CODEX_PATH` if Codex is installed elsewhere.

## Tapping a task card does not open Codex Desktop

Confirm Codex Desktop is installed and owns the `codex` URL scheme, then relaunch both apps and tap the card again. Navigation accepts only a real UUID-backed task and fails closed for placeholders or malformed catalog entries. If the task still does not open after a Codex Desktop update, include both app versions and sanitized logs in an issue. The model/effort label is display-only and never opens a settings surface.

## Thread title or context does not change when switching threads

Confirm Codex Desktop is frontmost, switch tasks once, and wait about one second. Then relaunch the helper. The helper follows `thread_stream_view_activity_changed` metadata in Codex Desktop's bounded local log tail and does not require Accessibility permission. After leaving Codex, the last confirmed title is intentionally pinned.

If the Codex Desktop log format has changed, the helper keeps the last confirmed thread rather than guessing from background token activity. As a temporary compatibility fallback, you can enable **System Settings > Privacy & Security > Accessibility > RehireBar** and relaunch; this fallback is read-only and never synthesizes input.

## A remote task shows `—`, `IDLE`, `SYNC`, or no context

- `SYNC` means the host is connecting, offline, errored, or Desktop has not finished reconnect recovery. It intentionally overrides an old `RUN`/`WAIT`/`COMPACT` value.
- `—` means no fresh task runtime, exact-host turn boundary, or host connection event is available. Catalog writes can be title/settings/synchronization traffic and are never treated as proof of execution.
- `IDLE` means an explicit runtime or completion event established that the task is inactive; it is not inferred from catalog recency.
- A missing context bar means the owner snapshot is absent, invalid, or older than the context freshness window. The app never resumes a task or substitutes cumulative token usage to obtain a percentage.
- Repeated `no-client-found` failures use exponential backoff; they do not create another Remote Control owner or call task-control methods.

SSH Remote is regression-tested. Device-paired Remote Control remains conditional until the documented two-device acceptance run is completed for the current Desktop version. When reporting a failure, include only host kind, connection stage, app versions, and sanitized error category—never pairing codes, enrollment tokens, device keys, internal environment IDs, or conversation content.

## Build fails with `resource fork, Finder information, or similar detritus not allowed`

This can happen when the repository is inside iCloud Drive or another File Provider-backed folder. The provider can attach Finder metadata to an `.app` or `.xctest` bundle while Xcode is signing it.

Clone the repository into a normal local development folder such as `~/Developer/rehirebar` and rebuild there. Repeatedly disabling code signing or Gatekeeper is not a supported workaround. The packaging script already verifies a clean staged copy for the final ZIP.

## Collect sanitized logs

```bash
./scripts/dev.sh logs
```

Before posting logs publicly, remove usernames, home-directory paths, thread UUIDs, and any Codex content. Never attach `~/.codex/auth.json` or an entire session JSONL file.
