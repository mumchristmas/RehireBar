# RehireBar 0.5.5

## 收起后，不被后台打扰

- 启动时保持收起；点击 Control Strip 图标或菜单中的 **Show Touch Bar** 才展开。
- 数据刷新、任务切换、审批布局变化、Codex 前台激活及睡眠唤醒不再主动展开 Touch Bar。
- 收起期间继续监控任务、刷新数据，并让过期状态失效。
- 展示调用失败时，仅在本次用户操作内立即重试一次；移除后台自动重开和重启应用的恢复逻辑。

开发规范现要求每次更新或 debug 使用独立版本工作树，验证后以简洁提交合并到 main。

感谢 [Empsunrise](https://github.com/Empsunrise) 在
[Codex Status Touch Bar PR #2](https://github.com/binlabongbom/codex-status-touch-bar/pull/2)
中提出的用户主动展开原则，为本次改进提供了启发。

## Stay collapsed until you choose to open

RehireBar starts collapsed. Open it from the Control Strip icon or **Show Touch Bar**.
Background refresh, task changes, approval layouts, app activation, and wake events
update content without opening the bar. Independent task monitoring and stale-state
expiry continue while collapsed.

An explicit opening action gets at most one immediate composition-reset retry.
Background presentation recovery and application-relaunch escalation are removed.

Thanks to Empsunrise for the inspiration in the upstream PR linked above.

## Installation and updates / 安装与更新

- Apple silicon: `RehireBar-0.5.5-macos-arm64.zip`
- Intel: `RehireBar-0.5.5-macos-x86_64.zip`
- Requires macOS 15 or later and physical Touch Bar hardware for Touch Bar display.
- From 0.5.4, choose **Check for Updates…** to use the signed update feed.
- From 0.5.3 or earlier, install manually once to obtain the updater.
- Packages are ad-hoc signed, not Developer ID notarized. Sparkle update feeds and
  archives use the existing RehireBar Ed25519 publishing identity.

See [installation instructions](https://github.com/mumchristmas/RehireBar/blob/main/docs/INSTALLATION.md).

## Validation / 验证范围

The local regression suite passes 266 tests. Release builds, bundle verification,
both architecture packages, and an extracted Apple silicon launch with a live
monitoring snapshot were verified. Hosted macOS Apple silicon and Intel CI must
also pass before publication. Automated tests cover content-only updates, bounded
retries, wake refresh, and stale-state expiry. Physical collapse/restore and a full
sleep/wake cycle have not been independently confirmed for this build.
