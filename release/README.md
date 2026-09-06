# Release assets

Files in this directory are staged for GitHub Releases, not for Git history.

For `0.5.3`, upload:

- `RehireBar-0.5.3-macos-arm64.zip` — Apple silicon
- `RehireBar-0.5.3-macos-x86_64.zip` — Intel
- `SHA256SUMS`
- `RELEASE-NOTES-0.5.3.md`

The ZIP is built from this public directory and contains the complete ad-hoc-signed `RehireBar.app`. It is not notarized. Users who prefer source can reproduce the same bundle with `bash scripts/build-app.sh`.

Both packages require macOS 15+. Generate both from this public checkout with `bash scripts/build-release.sh`; it writes versioned ZIPs and `SHA256SUMS` to `release/`. Run `bash scripts/test-release.sh` to test the extracted app from `release/test/`.
`release/test/LAST-RUN.txt` records its exact process path and private status snapshot.
The app and diagnostics under `release/test/` are local-only. A translated Intel test run is not native Intel hardware acceptance.
