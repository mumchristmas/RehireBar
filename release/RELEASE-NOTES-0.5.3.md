# RehireBar 0.5.3

**Your Touch Bar is back on the payroll.**

Waiting tasks can now take the first card, and a new local diagnostic command
makes installation and compatibility easier to check.

## Changes

- Choose **Task order → Waiting first** to put waiting and failed tasks ahead of
  running tasks. **Running first** remains the default. The preference is saved
  and applies immediately; it does not open a task or reopen a collapsed Touch Bar.
- Add **`doctor --json`** with a versioned JSON Schema. It reports the actual
  desktop/CLI versions, Touch Bar detection, local source presence, URL registration,
  and cache freshness. Readiness is kept separate from untested runtime behavior.
- Add a compatibility matrix, diagnostic guide, and structured issue form.
  Codex inside the tested ChatGPT desktop application is identified by its actual
  Bundle ID, rather than inferred from the visible app name.
- Clarify how the coding agent you already use can help connect your tools and
  compile RehireBar using the included interface docs, examples, and build scripts.

## Downloads

| Mac | Archive |
| --- | --- |
| Apple silicon | `RehireBar-0.5.3-macos-arm64.zip` |
| Intel | `RehireBar-0.5.3-macos-x86_64.zip` |

Verify the archive against `SHA256SUMS`. Both builds require **macOS 15+** and a
**physical Touch Bar**. Xcode is needed only for source builds. The apps are
ad-hoc signed and not notarized; see the
[installation guide](https://github.com/mumchristmas/RehireBar/blob/v0.5.3/docs/INSTALLATION.md).

## Validation and boundaries

Build 14 passes all 262 XCTest cases on both Apple silicon and Intel macOS
runners in [CI](https://github.com/mumchristmas/RehireBar/actions/runs/34022349228).
The release archives pass the native executable, signature, architecture, and
checksum checks. Task display and independent monitoring were also tested on an
Apple silicon Mac with a physical Touch Bar.

Regression tests include three running tasks plus one waiting task, expired
waiting evidence, menu actions, and matching UI/diagnostic ordering. Doctor reports
were checked against the JSON Schema, including missing-dependency cases.

Private macOS and Codex interfaces remain version-sensitive. Native Intel Touch
Bar and paired-device Remote Control hardware acceptance are still incomplete.
Doctor does not open tasks, probe live IPC, or send approval answers; a registered
URL handler is not proof of successful task navigation. Approval controls require
explicit registration by the source agent. See
[compatibility](https://github.com/mumchristmas/RehireBar/blob/main/docs/COMPATIBILITY.md).

## 中文

**Touch Bar 又被叫回来上班了。**

0.5.3 新增可选的“等待优先”排序，让需要你处理的任务出现在运行任务之前；默认仍为
“运行优先”。排序偏好会保存，切换不会打开任务，也不会重新展开已收起的 Touch Bar。

新增 `doctor --json`，便于核对实际客户端与 CLI 版本、数据来源和缓存时效，同时明确
哪些操作尚未实测。兼容性说明、问题模板和中英文介绍也已更新。你可以把仓库交给熟悉的
编程 Agent，利用现成接口、示例和构建脚本完成接入与编译。

提供 Apple silicon 与 Intel 安装包及 `SHA256SUMS`。需要 macOS 15+ 和实体 Touch Bar；
安装包仍为 ad-hoc 签名，尚未公证。Apple silicon 和 Intel 的 macOS CI 各通过
262 项测试；这些结果不代替 Intel Touch Bar 与双设备 Remote Control 的实机验收。
