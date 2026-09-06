# Documentation

[English README](../README.md) · [简体中文 README](../README.zh-CN.md)

## Use RehireBar

- [Installation](INSTALLATION.md) — compatibility, source build, signing, installation, and removal.
- [Usage](USAGE.md) — task states, refresh behavior, navigation, approvals, collapse, and quit.
- [Troubleshooting](TROUBLESHOOTING.md) — safe recovery and sanitized issue reporting.

## Build and integrate

- [Architecture](ARCHITECTURE.md) — module boundaries, data flow, identity, freshness, and privacy.
- [Agent status interface](integrations/AGENT-STATUS-INTERFACE.md) — the provider-neutral JSON contract for custom and multi-Agent systems.
- [Agent status JSON Schema](integrations/agent-status-v1.schema.json) — machine-readable v1 validation.
- [Minimal Agent example](integrations/examples/minimal-agent-status.json) — a deliberately fictional publisher payload.
- [Model display interface](integrations/MODEL-DISPLAY-INTERFACE.md) — abbreviation rules, precedence, customization, and fallback behavior.
- [Model display rules and mapping tables](../Resources/ModelDisplay.json) — editable defaults, including `GPT6-astra` → `6.0A`.
- [Model display JSON Schema](integrations/model-display-v1.schema.json) — the versioned display-policy contract.
- [Approval integration](APPROVAL-INTEGRATION.md) — explicit decision gates and fail-closed delivery.

## Repository map

```text
.
├── .github/                 CI and contribution templates
├── Resources/               App metadata and original RehireBar icon
├── Sources/
│   ├── AgentStatusCore/     Foundation-only public contracts and cache
│   └── RehireBar/             Adapters, state resolution, AppKit, lifecycle
├── Tests/RehireBarTests/      Automated tests
├── docs/                    User and integration documentation
├── scripts/                 Build, verification, and developer entrypoints
├── Package.swift
├── README.md
└── README.zh-CN.md
```
