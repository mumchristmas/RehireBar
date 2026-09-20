# RehireBar 0.5.9

## 更新内容

- 修复审批切换后问题文本与按钮操作不一致，以及下一条审批按钮无法使用的问题。
- 修复多个进程同时登记审批时丢失请求的问题；到期审批会撤下，并在点击时重新验证。
- 为额度查询子进程退出设置时限，避免异常进程阻塞刷新和取消。
- 修复额度刷新失败后，任务刷新错误清除旧额度过期标记的问题。
- 远程主机恢复后，不再使用恢复前缓存的运行状态，同时保留仍有效的上下文用量。
- 模型重路由只取当前轮次，避免历史事件覆盖当前模型。
- 日志或数据库被原子替换后重新建立监听，保持后续状态更新及时。
- 修复思考进度与 Desktop 状态交替刷新时快速模式指示闪烁的问题。

## Changes

- Keep approval text, callbacks, and button state synchronized between requests.
- Serialize approval queue transactions across processes and revalidate expiry before delivery.
- Bound app-server shutdown and keep cancellation from waiting on an unresponsive child process.
- Preserve stale quota status through task-only refreshes after a failed quota refresh.
- Reject remote runtime state from before host recovery while retaining eligible context data.
- Resolve model reroutes from the current turn instead of historical events.
- Reattach file watchers after atomic replacement.
- Keep the fast-mode indicator stable across reasoning progress and Desktop refreshes.

## Installation and updates / 安装与更新

- Apple silicon: `RehireBar-0.5.9-macos-arm64.zip`
- Intel: `RehireBar-0.5.9-macos-x86_64.zip`
- Requires macOS 15 or later and physical Touch Bar hardware for the display.
- From 0.5.7 or later, choose **Check for Updates…** to use the signed update feed.
- From 0.5.6 or earlier, quit the old app and manually replace it because 0.5.7 changed the bundle identifier.
- Packages are ad-hoc signed and not Developer ID notarized.

[Installation instructions](https://github.com/mumchristmas/RehireBar/blob/main/docs/INSTALLATION.md)

## Validation / 验证范围

Regression tests cover native AppKit approval-item reuse, expiry, concurrent queue writers, unresponsive child processes, quota/task refresh ordering, cached remote recovery, model history, and replacement-file notifications. Physical Touch Bar interactions, native Intel Touch Bar hardware, and actual approval delivery to a live task remain separate manual acceptance checks.
