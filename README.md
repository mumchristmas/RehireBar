<p align="center">
  <img src="Resources/AppIcon-1024.png" width="112" alt="RehireBar: one continuous strip with three task indicators">
</p>

# RehireBar

**Your Touch Bar is back on the payroll.**

RehireBar shows local and remote AI tasks, model, context, and quota on your MacBook Pro's Touch Bar. Codex is supported out of the box.

[简体中文](README.zh-CN.md) · [Docs](docs/README.md)

![RehireBar on a physical Touch Bar: remaining quota, a running task, a remote waiting task, and an idle task](docs/assets/rehirebar-touchbar-en.png)

<sub>Real Touch Bar capture with example task names and values. Left: quota remaining and reset time. Each task: status, model/effort, and context used. Running tasks also show elapsed time.</sub>

- See running, waiting, failed, syncing, and unknown task states.
- Tap a task to open it. Swipe for the rest.
- Unavailable data stays hidden. Stale active states expire.
- Collapse it, and ordinary refreshes leave it collapsed.

## Install

Requires **macOS 15+** and a **physical Touch Bar**. The Codex integration needs Codex CLI; task navigation needs Codex Desktop.

Download **[Apple Silicon](https://github.com/mumchristmas/RehireBar/releases/download/v0.5.2/RehireBar-0.5.2-macos-arm64.zip)** or **[Intel](https://github.com/mumchristmas/RehireBar/releases/download/v0.5.2/RehireBar-0.5.2-macos-x86_64.zip)** from the [latest release](https://github.com/mumchristmas/RehireBar/releases/latest), verify its checksum, and move the extracted app to Applications.

The app is ad-hoc signed and not notarized. See [Installation](docs/INSTALLATION.md) for first launch. Xcode is only needed to build from source:

```bash
bash scripts/build-app.sh
open 'dist/RehireBar.app'
```

## Extend RehireBar

To connect another agent, build a status publisher that atomically writes to `~/Library/Application Support/RehireBar/agents/<provider>.json`. The existing UI reads the shared contract.

- Start with the [interface contract](docs/integrations/AGENT-STATUS-INTERFACE.md), [JSON Schema](docs/integrations/agent-status-v1.schema.json), and [example document](docs/integrations/examples/minimal-agent-status.json).
- Customize model abbreviations through the [model display interface](docs/integrations/MODEL-DISPLAY-INTERFACE.md), [rules and mapping tables](Resources/ModelDisplay.json), and [configuration Schema](docs/integrations/model-display-v1.schema.json).
- For changes to the app itself, read [AGENTS.md](AGENTS.md), [Architecture](docs/ARCHITECTURE.md), and [Contributing](CONTRIBUTING.md).

[Usage](docs/USAGE.md) · [Agent interface](docs/integrations/AGENT-STATUS-INTERFACE.md) · [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · [MIT](LICENSE)

Runs locally, with no project telemetry. Private macOS and Codex interfaces can change. Independent community project, not affiliated with Apple or OpenAI.

Based on [Codex Status Touch Bar](https://github.com/binlabongbom/codex-status-touch-bar) by Wongsakorn Uphonram. [Attribution](NOTICE.md).
