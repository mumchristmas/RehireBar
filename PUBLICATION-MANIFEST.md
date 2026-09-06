# Public release manifest

This directory is the complete and only GitHub publication boundary for RehireBar.

## Included

- Complete, buildable SwiftPM source in `Sources/`.
- Sanitized automated tests in `Tests/`.
- App metadata and the original RehireBar icon in `Resources/`.
- Reproducible local build and verification scripts in `scripts/`.
- English and Simplified Chinese READMEs, user guides, architecture, integration contracts, contribution policy, security policy, changelog, and the original MIT license attribution.
- Release notes, checksums, and locally staged binary assets under `release/`.

## Excluded by design

- Product requirement and design-process documents.
- Private development history, acceptance notes, and performance traces.
- Raw logs, session files, local databases, credentials, pairing material, and machine configuration.
- Screenshots containing real tasks, project names, host names, or account data.
- Local build caches, rollback bundles, and editor state.

## Publication rule

Treat this directory as the repository root. Do not publish its parent workspace. Binary ZIP files under `release/` are GitHub Release assets and are intentionally ignored by Git; upload them separately from this same public boundary.

The first public release was 0.5.2. Subsequent source changes and release assets
should retain their own reviewed history and matching version/build information.

## Suggested GitHub metadata

- Repository name: `RehireBar`
- Repository: `https://github.com/mumchristmas/RehireBar`
- Description: `Your Touch Bar is back on the payroll. Native Codex task monitoring for MacBook Pro; other agents connect through a shared status interface.`
- Topics: `touch-bar`, `touchbar`, `codex`, `codex-cli`, `ai-agents`, `macos`, `swift`, `macbook-pro`, `developer-tools`, `agent-status`

These are suggested publishing metadata, not a statement that the GitHub settings
have already changed. The spelling variants improve query coverage; no search-rank
gain is guaranteed. Add agent-specific topics only when a corresponding usable
integration exists.
