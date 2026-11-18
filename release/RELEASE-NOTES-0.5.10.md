# RehireBar 0.5.10

## 更新内容

- 修复 Codex Desktop 迁移任务目录后，正在运行的远程任务可能消失、旧任务仍占据前排的问题。新版 RehireBar 优先读取当前任务目录，并兼容仅有旧目录的安装。
- 使用已确认的回合开始时间补足排序依据，让仍在运行的任务按实际活动排序。
- 适配新版 Codex CLI 的内置路径。旧命令链接失效时，仍可读取实时额度。

## Changes

- Restore task discovery after Codex Desktop moves its catalog to `codex.db`. Keep support for installations that only have the legacy catalog.
- Use confirmed turn start times when ordering running tasks with outdated catalog timestamps.
- Restore live quota collection when the bundled CLI moves and the old command symlink is broken.

## Installation and updates / 安装与更新

- Apple silicon: `RehireBar-0.5.10-macos-arm64.zip`
- Intel: `RehireBar-0.5.10-macos-x86_64.zip`
- Requires macOS 15 or later and a physical Touch Bar for the display.
- From 0.5.7 or later, choose **Check for Updates…** in the RehireBar menu to use the signed update feed.
- From 0.5.6 or earlier, quit the old app and manually replace it because 0.5.7 changed the bundle identifier.

[Installation instructions](https://github.com/mumchristmas/RehireBar/blob/main/docs/INSTALLATION.md)
