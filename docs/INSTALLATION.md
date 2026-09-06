# Installation

RehireBar requires macOS 15 or later and a physical Touch Bar. The Codex integration needs Codex CLI; task navigation and approval delivery need Codex Desktop.

Check [Compatibility](COMPATIBILITY.md) for the tested desktop application and
version, including Codex inside the current ChatGPT desktop app. Other agents need
a status publisher; an interface alone does not install a Claude Code or OpenCode adapter.

## Download the app

Open the [latest release](https://github.com/mumchristmas/RehireBar/releases/latest) and download the ZIP for your Mac plus `SHA256SUMS`:

- `RehireBar-0.5.3-macos-arm64.zip` — Apple Silicon.
- `RehireBar-0.5.3-macos-x86_64.zip` — Intel.

Xcode is not required to use a downloaded app. Both builds require macOS 15+. Apple's [macOS Sequoia compatibility list](https://support.apple.com/en-us/120282) includes the 2018–2020 Intel Touch Bar MacBook Pro generations. The Intel build does not add support for the older macOS versions on 2016–2017 models.

In Terminal, calculate the checksum for your downloaded file; for example:

```bash
cd ~/Downloads
shasum -a 256 RehireBar-0.5.3-macos-arm64.zip
```

Compare the complete result with the matching filename in `SHA256SUMS`. Extract the ZIP, quit other Touch Bar status helpers, then move `RehireBar.app` to Applications and open it.

## First launch

The initial release is ad-hoc signed and not notarized. If macOS blocks it, first try opening the app, then use **System Settings → Privacy & Security → Open Anyway** and confirm. See [Apple's first-open instructions](https://support.apple.com/en-us/102445). Do not disable Gatekeeper globally.

The app runs in the background, with no Dock icon or main window. Its menu-bar icon provides **Show Touch Bar** and **Quit RehireBar**.

Tasks are monitored independently of the foreground app. Running tasks appear first; project and task activity determine the order within a state. Tap a card to open its task, and swipe to reach additional cards. Unknown data remains absent. See [Usage](USAGE.md).

When installed in Applications, RehireBar registers its login item. If macOS asks for confirmation, enable it in **System Settings → General → Login Items**. Log out and back in to check startup.

## Build from source

Source builds require full Xcode with Swift 6 and a macOS 15 SDK or later, plus Git and the Xcode command-line tools.

```bash
git clone https://github.com/mumchristmas/RehireBar.git
cd RehireBar
swift test
swift build -c release
bash scripts/build-app.sh
bash scripts/verify-app.sh
open 'dist/RehireBar.app'
```

The default build produces `dist/RehireBar.app` and `dist/RehireBar.zip` for the current Mac. To install it permanently, quit RehireBar and extract the ZIP into Applications:

```bash
sudo ditto -x -k 'dist/RehireBar.zip' /Applications
open '/Applications/RehireBar.app'
```

For an architecture-specific build:

```bash
bash scripts/build-app.sh --arch x86_64
bash scripts/verify-app.sh 'dist/x86_64/RehireBar.app' x86_64
```

Use `--arch arm64` for Apple Silicon. `bash scripts/build-release.sh` creates both versioned ZIPs and `SHA256SUMS` under `release/`. Each bundle includes the MIT license and upstream attribution in `Contents/Resources/`.

For local release acceptance, `bash scripts/test-release.sh --build` verifies the archive and launches its extracted app under `release/test/`. It records the process path and private diagnostics without replacing Downloads or Applications copies. See [Contributing](../CONTRIBUTING.md).

## Custom Codex locations

The login item does not inherit your interactive shell PATH. RehireBar looks for
Codex CLI at `~/.local/bin/codex`, the bundled executable in
`/Applications/ChatGPT.app/Contents/Resources/codex`, `/opt/homebrew/bin/codex`, and
`/usr/local/bin/codex`, in that order.

For a launch from a shell, override the executable or Desktop bundle identifier when needed:

```bash
export REHIREBAR_CODEX_PATH='/absolute/path/to/codex'
export REHIREBAR_BUNDLE_ID='your.codex.bundle.identifier'
'/Applications/RehireBar.app/Contents/MacOS/RehireBar'
```

Run the executable directly for this shell-specific override; quit an already
running RehireBar first. This does not configure the separately launched login item.
In RehireBar 0.5.3 and later, use [the doctor command](DIAGNOSTICS.md) to see which
desktop bundle and CLI version the current process detects.

## In-app updates

For in-app upgrades, see [Application updates](UPDATES.md). The updater needs its
signed architecture-specific feed published alongside the release archives.
Versions that predate this updater require one manual installation of an
updater-enabled release before in-app upgrades become available.

## Developer ID distribution

Maintainers can set `REHIREBAR_SIGNING_IDENTITY` to their Developer ID Application identity when running `scripts/build-app.sh`. Developer ID signing and notarization require a separate distribution setup; this first release uses ad-hoc signing.

## Uninstall

Disable RehireBar in **System Settings → General → Login Items**, quit it from its menu-bar icon, then move `/Applications/RehireBar.app` to the Trash.
