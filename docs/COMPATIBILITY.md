# Compatibility and acceptance

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

OpenAI now documents Codex within the [ChatGPT desktop application](https://learn.chatgpt.com/docs/quickstart).
The visible application name and Bundle ID need not match.

The local inspection on **2026-09-06** found:

| Item | Observed value |
| --- | --- |
| RehireBar version / build | `0.5.3` / `14` |
| Desktop application | `ChatGPT.app` |
| Desktop version / build | `26.901.41600` / `7982` |
| Desktop Bundle ID | `com.openai.codex` |
| Bundled CLI | `codex-cli 0.153.4` |
| Host | `MacBookPro17,1`, Apple silicon, macOS `27.0` |

The existing `com.openai.codex` default matches this installed app. Renaming the
application to ChatGPT therefore does not by itself establish a detection bug.
This observation is version-specific, not a promise for every ChatGPT release or
older ChatGPT application. Use [doctor](DIAGNOSTICS.md) to inspect the actual host.
The bundled CLI path is already part of the app's executable resolution policy.

## Hardware and acceptance boundaries

Both architectures require **macOS 15 or later and a physical Touch Bar**. The Intel
ZIP does not lower that requirement. Apple's [Sequoia compatibility list](https://support.apple.com/en-us/120282)
includes the 2018–2020 Intel Touch Bar MacBook Pro generations; it does not include
the 2016–2017 models. Supporting their older operating systems requires a separate
API and hardware validation effort.

| Check | Current evidence |
| --- | --- |
| Apple silicon task display and independent monitoring | 0.5.3 build 14 launched from its verified release ZIP; physical Touch Bar display and the independent task collection were observed on the host above. |
| Automated regressions | 262 XCTest cases passed in the development and public source trees; 262 also passed as x86_64 under Rosetta on the same Mac. |
| Three RUN tasks plus one WAIT | Regression case for both ordering modes; waiting-first puts WAIT ahead of the three RUN cards. |
| Expired WAIT / lost source | Regression evidence: state becomes unknown and loses waiting priority. |
| Native Intel Touch Bar behavior | Not yet accepted on physical Intel hardware. |
| Intel executable | Cross-build and Rosetta tests are useful evidence, but do not replace the preceding hardware check. |
| `codex://` registration | A readiness check; actual card navigation requires a user tap and confirmation of the destination task. |
| Approval answer delivery | Explicit registration and confirmed delivery must be tested together on the target desktop version. |
| Paired-device Remote Control | Needs a second device covering idle, run, wait, compaction, disconnect, recovery, and controller exit. |
| Developer ID notarization | Current published release is ad-hoc signed and not notarized. |

For each new acceptance row, record RehireBar version/build, macOS, hardware model,
process architecture/translation, desktop version/build, CLI version, the operation,
and its observed result. Keep readiness, automated regression, and physical
acceptance as separate evidence. A successful build does not certify private
macOS or Desktop interfaces on another version.
