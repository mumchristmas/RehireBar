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

Treat this directory as the future repository root. Do not publish its parent workspace. Binary ZIP files under `release/` are GitHub Release assets and are intentionally ignored by Git; upload them separately from this same public boundary.

The first public release is 0.5.2. Publish the sanitized source snapshot as one initial commit and upload only the matching release assets.

## Suggested GitHub metadata

- Repository name: `RehireBar`
- Repository: `https://github.com/mumchristmas/RehireBar`
- Description: `Open-source Touch Bar status rail for Codex and other AI agents on MacBook Pro: local and remote tasks, context, model, quota, sync, and approvals.`
- Topics: `touch-bar`, `codex`, `ai-agents`, `macos`, `swift`, `macbook-pro`, `developer-tools`, `agent-status`
