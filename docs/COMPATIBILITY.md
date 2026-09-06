# Compatibility

RehireBar is a native macOS Touch Bar monitor. Codex is the built-in integration;
other agents publish the [shared status contract](integrations/AGENT-STATUS-INTERFACE.md).
No Claude Code or OpenCode adapter is bundled with the app.

## Choose the right integration

| Environment | Current support |
| --- | --- |
| Codex in a compatible desktop application, with Codex CLI available | Built-in quota, task, model, and context collection. Task opening uses the desktop's registered `codex://` handler. |
| Codex CLI without the desktop | Display fallback from the CLI and eligible local session logs. Desktop task-catalog monitoring, task opening, and approval delivery are unavailable or conditional. |
| Claude Code, OpenCode, or another agent | A publisher must be installed or implemented. Schema support is a display interface, not a shipped integration. |
| SSH-hosted Codex tasks | Composite identity and host/runtime recovery have regression coverage. Validate the installed desktop version and remote host together. |
| Paired-device Remote Control | Conditional; the complete two-device acceptance matrix has not been completed. |

Approval buttons require an agent to [register a decision gate](APPROVAL-INTEGRATION.md).
They do not automatically replace every native Codex permission prompt. Registering
a question and delivering its answer are separate operations; delivery needs an
exact-thread acknowledgement from Desktop.

## Desktop identity

RehireBar locates Desktop by its Bundle ID, which can differ from the visible
application name. The default is `com.openai.codex`; use
[doctor](DIAGNOSTICS.md) to check the installed application and CLI.
See [custom Codex locations](INSTALLATION.md#custom-codex-locations) when an
override is needed. Desktop integration uses version-sensitive interfaces, so
successful detection alone does not establish that task opening or approval
delivery works with a particular release.

## Hardware and acceptance boundaries

Both architectures require **macOS 15 or later and a physical Touch Bar**. The Intel
ZIP does not lower that requirement. Apple's [Sequoia compatibility list](https://support.apple.com/en-us/120282)
includes the 2018–2020 Intel Touch Bar MacBook Pro generations; it does not include
the 2016–2017 models. Supporting their older operating systems requires a separate
API and hardware validation effort.

| Check | Current evidence |
| --- | --- |
| Apple silicon task display and independent monitoring | Manually tested with the 0.5.3 release package on a physical Touch Bar. |
| Automated regressions and release archives | [0.5.3 CI](https://github.com/mumchristmas/RehireBar/actions/runs/34022349228) passed 262 XCTest cases on both Apple silicon and Intel macOS runners and checked their native release archives. |
| Three RUN tasks plus one WAIT | Regression case for both ordering modes; waiting-first puts WAIT ahead of the three RUN cards. |
| Expired WAIT / lost source | Regression evidence: state becomes unknown and loses waiting priority. |
| Native Intel Touch Bar behavior | Not yet accepted on physical Intel hardware. |
| Intel executable | Native Intel CI checks the executable and tests; it does not validate physical Touch Bar behavior. |
| `codex://` registration | A readiness check; actual card navigation requires a user tap and confirmation of the destination task. |
| Approval answer delivery | Explicit registration and confirmed delivery must be tested together on the target desktop version. |
| Paired-device Remote Control | Needs a second device covering idle, run, wait, compaction, disconnect, recovery, and controller exit. |
| Developer ID notarization | Current published release is ad-hoc signed and not notarized. |

For each new acceptance row, record RehireBar version/build, macOS, hardware model,
process architecture/translation, desktop version/build, CLI version, the operation,
and its observed result. Keep readiness, automated regression, and physical
acceptance as separate evidence. A successful build does not certify private
macOS or Desktop interfaces on another version.
