# RehireBar 0.5.4

**Your Touch Bar is back on the payroll.**

The menu now shows the installed version and offers a signed in-app update workflow.

## Changes

- Show the installed version and build in the menu. Add **`--version`** to inspect
  a packaged app without launching its interface; use the bundle version in client
  initialization and diagnostics.
- Add **Check for Updates…** with Sparkle 2.9.6 and separate Apple silicon and
  Intel feeds. Users choose when to check, install, and restart. Background checks,
  unattended installation, and system profiling are off by default.
- Require signed update feeds and validate update archives before extraction.
  An unavailable feed is reported as an error; current or newer installed builds
  are kept. Signing keys stay outside the source tree.
- Add release scripts that generate and verify signed feeds for the exact release
  archives. Rebuilding archives clears old feeds so their signatures cannot be
  accidentally reused.
- Normalize bundle permissions after code signing, including generated signature
  files, so packages built with a private umask remain readable by other users.

## Downloads and first upgrade

| Mac | Archive |
| --- | --- |
| Apple silicon | `RehireBar-0.5.4-macos-arm64.zip` |
| Intel | `RehireBar-0.5.4-macos-x86_64.zip` |

Download the archive for your Mac and verify it against `SHA256SUMS`.
Signed `appcast-arm64.xml` and `appcast-x86_64.xml` feeds are included for
in-app update checks.

Versions up to 0.5.3 need one manual installation of this updater-enabled release.
Both builds require **macOS 15+** and a **physical Touch Bar**. Packages remain
ad-hoc signed and are not notarized. See
[installation](https://github.com/mumchristmas/RehireBar/blob/v0.5.4/docs/INSTALLATION.md)
and [application updates](https://github.com/mumchristmas/RehireBar/blob/v0.5.4/docs/UPDATES.md).

## Validation and boundaries

Build 15 passes all 266 XCTest cases in both source trees and all 266 as x86_64
under Rosetta. Native release builds, packaging, and bundle verification pass,
including a restrictive-umask build. Both packaged executables report the expected
version through `--version` and `doctor --json`. The extracted Apple silicon app
runs from its release directory and continues publishing independent task state.

Five isolated Sparkle integration cases cover installation and relaunch, current
version handling, downgrade prevention, and modified feed/archive rejection without
replacing the installed fixture. Menu actions and update availability are covered
by AppKit tests; automated visual inspection of the menu-bar app was unavailable.

Public feed signatures and download checksums are verified separately after
publication. Administrator-authorized installation, native Intel Touch Bar
behavior, and paired-device Remote Control still require separate acceptance.
The existing private macOS and Codex interface limits still apply.

## 中文

**Touch Bar 又被叫回来上班了。**

0.5.4 在菜单中显示版本与构建号，并新增“Check for Updates…”检查更新入口；也可用
`--version` 查询安装包版本。更新源和安装包均经过签名验证，由你决定检查、安装和重启，
默认不在后台检查或自动安装。0.5.3 及更早版本需要先手动安装一次包含升级功能的新版本。

提供 Apple silicon 与 Intel 安装包、两个签名更新源和 `SHA256SUMS`。首次安装后，
可通过菜单检查后续版本。266 项测试在本机原生及 Rosetta 环境均通过，另通过五项隔离升级测试。
应用仍要求 macOS 15+ 和实体 Touch Bar，安装包采用 ad-hoc 签名，尚未公证；
需要管理员授权的安装以及原生 Intel 实机仍需单独验收。
