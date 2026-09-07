# RehireBar 0.5.6

## 更新内容

- 新增 **Agents** 菜单，查看 Codex 与状态文件集成的连接状态，分别控制各 Agent 的任务及远程任务显示。隐藏卡片后仍继续监控，修改显示选项不会展开已收起的 Touch Bar。
- 使用原生红黄绿状态灯和简短标签展示 Agent 连接情况，悬停可查看状态依据。
- 归档 Codex 任务后移除对应卡片，包括当前选中任务和最后一个任务；检查按本地主机隔离。
- 修复旧 Fast mode 设置在更新设置已清除后重新出现的问题。

## Changes

- Add an **Agents** menu with connection status and persistent per-Agent task and remote-task visibility preferences. Monitoring continues while cards are hidden, and preference changes keep the Touch Bar collapsed.
- Show native traffic-light status icons, concise connection labels, and evidence details in tooltips.
- Remove archived Codex tasks, including selected tasks and the last task in a catalog, with host-scoped archive checks.
- Prevent historical Fast mode settings from resurfacing after a newer setting clears them.

## Installation and updates / 安装与更新

- Apple silicon: `RehireBar-0.5.6-macos-arm64.zip`
- Intel: `RehireBar-0.5.6-macos-x86_64.zip`
- Requires macOS 15 or later; Touch Bar display requires physical Touch Bar hardware.
- From 0.5.4 or later, choose **Check for Updates…** to use the signed update feed. Earlier versions need one manual installation.
- Packages are ad-hoc signed, not Developer ID notarized. Update feeds and archives use the existing RehireBar Ed25519 publishing identity.

[Installation instructions](https://github.com/mumchristmas/RehireBar/blob/main/docs/INSTALLATION.md)

## Validation / 验证范围

Release acceptance includes the local regression suite, release build and bundle verification, extracted application launch, and native Apple silicon and Intel hosted CI. Published archives are selected from their native CI runners and verified again before signing and publication. Physical Touch Bar interaction and a full sleep/wake cycle remain unverified for this build.
