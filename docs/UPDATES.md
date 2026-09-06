# Application updates

Open the menu-bar icon to see RehireBar's installed version and build. Choose
**Check for Updates…** to check the release feed. If a compatible newer build is
available, the update window shows its release information and lets you install
and restart. If the installed build is current or newer than the feed, it is kept.
An unavailable feed is reported as an error, not as “up to date.”

You can inspect a packaged app without launching its interface:

```bash
'/Applications/RehireBar.app/Contents/MacOS/RehireBar' --version
```

The installed bundle is the version source. A bare development executable may
report that the version is unavailable; it must not report the version of its
test host. The existing `doctor --json` command also includes bundle information.

## Control and compatibility

Update checks are manual by default. Automatic checking, unattended installation,
and system profiling are disabled in the shipped configuration. Monitoring task
status does not trigger an update request.

The first release containing this updater needs one manual installation for users
of versions up to 0.5.3. Adding an updater cannot change code that is already
installed on those Macs. After that installation, the app can update itself from
the signed feed. The first public updater-enabled release must include the feed
assets described below; the previous public release does not provide them.

Each architecture has its own feed and package. An Intel build follows the Intel
feed even under Rosetta. The feed declares the update's build number and minimum
macOS/hardware requirements; an incompatible build is not installed. Sparkle
compares the monotonically increasing `CFBundleVersion`, while displaying the
marketing version from `CFBundleShortVersionString`.

The updater uses [Sparkle 2.9.6](https://github.com/sparkle-project/Sparkle/releases/tag/2.9.6).
It handles downloading, signature validation, installation, and relaunch. A signed
update is separate from Developer ID notarization: the current ad-hoc distribution
still needs its normal first-launch handling. Install the app in a writable,
permanent location; macOS may request authorization for protected destinations.

## Signing identity

The public Ed25519 key is stored in `Resources/Info.plist` as `SUPublicEDKey`.
The RehireBar publishing key is kept in the maintainer's login Keychain under
the account `com.bigbom.RehireBar.updates`. It is not stored in the repository.
Sparkle's `generate_keys --account com.bigbom.RehireBar.updates -p` prints only
the corresponding public key and does not generate or replace a key.

Keep a secure backup using Sparkle's documented key-export procedure. Losing this
key can require a manual reinstall when distributing ad-hoc signed apps. Do not
change the bundled public key casually, and do not turn off verification to work
around a signing failure. See [Sparkle's key guidance](https://sparkle-project.org/documentation/#eddsa-ed25519-signatures).

For a fork, use your own feed URL and signing key before distributing updates.
Generate a key with the resolved Sparkle tool and an account specific to your
project, then put its public key in your app's Info.plist. Private seeds stay in
Keychain or a separately protected publishing environment.

## Prepare a release

First build and validate the project using the normal required checks. Then:

```bash
bash scripts/build-release.sh --sign-updates
```

The ordinary `build-release.sh` remains usable without access to a production key;
it builds the archives and clears any old feeds whose signatures would no longer
match. The optional signing step reads the existing key,
checks it against the bundled public key, and verifies the archive's version,
identity, architecture, and checksums before generating the feeds.

For a separately protected 32-byte Sparkle seed file, set
`REHIREBAR_SPARKLE_KEY_FILE` to its path. The script prints no private seed and
never copies that file into the output. `REHIREBAR_UPDATE_KEY_ACCOUNT` selects a
different Keychain account. `REHIREBAR_RELEASE_REPOSITORY` selects a fork's
`owner/repository` for download links; also update the feed URL in Info.plist.

`release/RELEASE-NOTES-<version>.md`, when present, is embedded in the signed feed.
The signing step stages its inputs and copies the feeds out only after both
architectures have passed verification. It creates:

- `RehireBar-<version>-macos-arm64.zip`
- `RehireBar-<version>-macos-x86_64.zip`
- `appcast-arm64.xml`
- `appcast-x86_64.xml`
- `SHA256SUMS`, covering the archives and both feeds

Upload all five files to the same stable GitHub Release after reviewing them.
The packaged feeds point to `releases/latest/download/appcast-<architecture>.xml`;
the signed archive links point to the matching immutable version tag. Do not edit
signed XML or archives after signing; regenerate the feeds and checksums instead.
Generating these files does not publish a release.

## Validation

Run `python3 scripts/test-updater.py` on a logged-in Mac after resolving packages.
It builds disposable fixture apps, signs a loopback-only feed using a fresh test
key, and tests installation/relaunch, current-version handling, downgrade prevention,
and tampered feed/archive rejection. It leaves results under `artifacts/update-tests/`
and removes the test seed. The production application, key, and installation are
not involved in that test.

Run `bash scripts/test-release.sh --build` before final signing to inspect the actual application
from its release directory. Verify the displayed version, menu action, framework
loading, and normal task monitoring. Then run `bash scripts/generate-appcast.sh`
to sign those verified archives. Rebuilding archives after signing requires
generating the feeds again. Public feed availability and installations
requiring administrator authorization remain separate release acceptance checks.
