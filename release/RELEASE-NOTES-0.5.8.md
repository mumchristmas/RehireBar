# RehireBar 0.5.8

## 更新内容

- 修复 Touch Bar 空间不足时任务区域整块消失、只剩周用量的问题。任务区现在可以收缩，并按实际宽度调整同时显示的卡片数量；其余任务仍可横向浏览。
- 修复远程 Codex 任务计时在思考、工具调用及上下文压缩之间重置的问题，改为从当前对话轮次开始计时。

## Changes

- Keep task cards visible when Touch Bar space is constrained. The task area exposes its readable minimum width to AppKit and adapts the visible card count to its actual allocation.
- Measure remote Codex task elapsed time from the current conversation turn start, preserving the timer across reasoning, tool calls, and context compaction.

## Installation and updates / 安装与更新

- Apple silicon: `RehireBar-0.5.8-macos-arm64.zip`
- Intel: `RehireBar-0.5.8-macos-x86_64.zip`
- Requires macOS 15 or later and physical Touch Bar hardware for the display.
- From 0.5.7, choose **Check for Updates…** to install using the signed update feed.
- From 0.5.6 or earlier, quit the old app and manually replace it because 0.5.7 changed the bundle identifier.
- Packages are ad-hoc signed and not Developer ID notarized.

[Installation instructions](https://github.com/mumchristmas/RehireBar/blob/main/docs/INSTALLATION.md)

## Validation / 验证范围

The task-display fix was confirmed by the user on an Apple silicon Mac with physical Touch Bar hardware before this version bump. Automated checks cover minimum fitting width, resizing without losing tasks, and remote turn timing. Native Intel Touch Bar behavior, a full sleep/wake cycle, and paired-device Remote Control remain unverified for this release.
