# RehireBar 0.5.2

**Your Touch Bar is back on the payroll.**

The first public release of RehireBar brings AI task status to the MacBook Pro Touch Bar, with built-in Codex support and an open status interface for other agents.

## Highlights

- Independent local and remote task cards, with running tasks and recent project activity first.
- Task state, model, effort, elapsed time, context, and available account quota.
- Freshness-aware status: missing data stays absent and expired active states become unknown.
- Tap-to-open navigation, explicit approval controls, persistent manual collapse, and menu-bar restore.
- Editable model display mappings and a documented Agent JSON interface.

## Downloads

| Mac | Archive |
| --- | --- |
| Apple Silicon | `RehireBar-0.5.2-macos-arm64.zip` |
| Intel | `RehireBar-0.5.2-macos-x86_64.zip` |

Both builds require **macOS 15+** and a **physical Touch Bar**. The Codex integration needs Codex CLI; task navigation and approval delivery need Codex Desktop. Xcode is only required to build from source.

Verify the downloaded file against `SHA256SUMS`, extract the ZIP, and move the app to Applications. The bundles are ad-hoc signed and not notarized; follow the [installation guide](https://github.com/mumchristmas/RehireBar/blob/v0.5.2/docs/INSTALLATION.md) for first launch.

## Compatibility and validation

All 250 XCTest tests pass on Apple Silicon and as x86_64 under Rosetta. Build 13 covers task identity, runtime freshness, ordering, model display, and lifecycle behavior. Both release architectures pass signature, architecture, license, permissions, private-path, and checksum checks; the extracted Apple Silicon app also passes the local launch check.

RehireBar uses private macOS Touch Bar and version-sensitive Codex interfaces. Native Intel Touch Bar and paired-device Remote Control acceptance are not completed for this release. Automated tests and Rosetta execution do not replace those hardware checks.

## 中文

**Touch Bar 又被叫回来上班了。**

这是 RehireBar 的首次公开发布。它独立监控本地与远程 AI 任务，优先展示运行中的任务和近期活跃项目，并显示可用的模型、上下文和额度信息。内置支持 Codex，其他 Agent 可通过统一状态接口接入。

下载适合你的 Apple Silicon 或 Intel 安装包，核对 `SHA256SUMS` 后解压并移入“应用程序”。需要 macOS 15 或更新版本和实体 Touch Bar；使用安装包不需要 Xcode。应用使用 ad-hoc 签名，尚未进行 Apple 公证。

## Attribution

Derived from [Codex Status Touch Bar](https://github.com/binlabongbom/codex-status-touch-bar), originally created by Wongsakorn Uphonram. The MIT license and original copyright notice are preserved in the source and application bundles.
