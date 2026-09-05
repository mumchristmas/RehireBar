# Contributing

Thank you for improving RehireBar.

## Before opening an issue

- Read the README limitations and troubleshooting guide.
- Search existing issues.
- Reproduce on a supported macOS version.
- Remove personal data, thread UUIDs, prompts, responses, usernames, and home-directory paths from logs and screenshots.

## Development workflow

1. Fork the repository and create a focused branch.
2. Add or update tests for behavior changes.
3. Run:

   ```bash
   swift test
   swift build -c release
   bash scripts/build-app.sh
   bash scripts/verify-app.sh
   ```

4. On physical Touch Bar hardware, manually check any affected presentation, sleep/wake, Control Strip, or approval behavior.
5. Open a pull request describing the change, user impact, validation, and known limitations.

Keep pull requests focused. Do not include credentials, raw Codex sessions, generated build directories, or private machine paths.

For day-to-day local work, `./scripts/dev.sh` builds and tests the release archive
through `scripts/test-release.sh --build`. The app runs directly under `release/test/`.
Use `./scripts/dev.sh run` for the native `dist/` bundle; `debug`, `logs`, and `verify`
retain their development flows. Put repeatable project commands in `scripts/`,
user-facing documentation in `docs/`, and private evidence outside the public export.

`Resources/AppIcon-1024.png` is the app icon master. After changing it, run `bash scripts/build-icon.sh` to regenerate all ICNS sizes. Menu-bar and Control Strip symbols are native monochrome templates in `StatusTrayButtonFactory.swift` so they remain legible in both system appearances.

Model labels are defined by [the model display interface](docs/integrations/MODEL-DISPLAY-INTERFACE.md). Edit `Resources/ModelDisplay.json` for default rules and mappings, or use the documented local override. Keep the documented tables synchronized when changing shipped defaults; keep raw model IDs intact and model-family parsing out of the presenter.

Add user-visible changes to the appropriate category under `Unreleased` in `CHANGELOG.md`.

Generated app bundles belong in `dist/`. Raw screenshots, logs, and rollback bundles are local artifacts and must not be committed; publish only minimal, sanitized evidence under `docs/assets/`.

The packaging script remaps source paths and strips debug-map records from its binary copy before signing. Local SwiftPM build products retain their debugging information. Bundle verification rejects embedded home-directory paths.
It also selects the compiler and SDK from the same Xcode installation, avoiding a
cached Command Line Tools SDK being paired with a different Xcode compiler.

For release packaging, `bash scripts/build-release.sh` builds and verifies separate
Apple silicon and Intel ZIPs plus `SHA256SUMS` under `release/`. Verification checks
each Mach-O architecture so the filename cannot silently mislabel a build.

To build, verify, and run the release on this Mac:

```bash
bash scripts/test-release.sh --build
```

Without `--build`, it tests the existing archive matching `Resources/Info.plist`.
Use `--arch x86_64` to select the Intel archive on a Mac capable of running it.
The workflow verifies the checksums and bundle, stops a running RehireBar app, and
opens the extracted app in `release/test/<version>-<build>-<architecture>/`.
It verifies that exact process path and the PID in its live `status.json`, then
writes `release/test/LAST-RUN.txt`. The JSON preserves the actual collection order
and reports state, project identity, activity time, and observation time separately.
These local test files can contain private task metadata and are ignored by Git.
Downloads and Applications copies are not replaced. Cross-compilation and
translated tests do not replace physical Intel Touch Bar acceptance.

On Apple silicon with Rosetta already installed, run the Intel XCTest suite with:

```bash
arch -x86_64 /usr/bin/swift test --triple x86_64-apple-macosx15.0 --disable-swift-testing
```

All current tests use XCTest. The final flag disables the unused Swift Testing runner, which can otherwise launch with the host architecture and fail to load the Intel test bundle. On native Intel hardware, use the ordinary `swift test` command.

## Code style

- Prefer small, testable Swift types.
- Keep local data reads bounded and symlink-safe.
- Preserve fail-closed behavior for task navigation and approvals.
- Do not restart system Touch Bar services or alter global Touch Bar preferences.
- Treat private macOS and Codex Desktop APIs as version-sensitive boundaries.

By contributing, you agree that your contribution is licensed under the MIT License.
