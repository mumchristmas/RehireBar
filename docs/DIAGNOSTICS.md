# Diagnostics

The `doctor` command is available in RehireBar 0.5.3 and later. It emits a versioned
JSON report that a person or agent can inspect before investigating a missing card.

```bash
'/Applications/RehireBar.app/Contents/MacOS/RehireBar' doctor --json
```

For a local build, use `dist/RehireBar.app/Contents/MacOS/RehireBar`. For a release
test, use the executable inside the app path recorded in `release/test/LAST-RUN.txt`.
Running a bare SwiftPM executable can leave the app's version/build fields absent;
the packaged bundle supplies those fields.

The command does not start monitoring, register a login item, create status files,
open a task, connect to Desktop IPC, or submit an approval. It reads the same CLI
resolution policy used by the app and runs only `codex --version`, with a two-second
deadline and a 4 KiB output limit. It reads at most 64 KiB of the local status cache.

## Interpret the report

`schemaVersion` is `1`; the [JSON Schema](doctor-v1.schema.json) defines the fields.
Unknown optional facts are omitted. Exit `0` means a report was generated, including
when a dependency is missing. Invalid arguments exit `2`; report encoding failure
exits `1`. `doctor` without `--json` emits the same JSON.

| Field | What it establishes |
| --- | --- |
| `app`, `desktop`, `cli` | The actual bundle names/IDs, versions/builds, and resolved CLI version; no home-directory paths. |
| `host.processArchitecture`, `host.processTranslated` | The diagnostic executable's architecture and, when macOS exposes it, whether it runs under translation. An x86_64 process is not proof of native Intel hardware. |
| `host.hardwareModel`, `host.touchBar` | Model identifier and physical Touch Bar detection. `not-detected` can also mean the private detection API is unavailable. |
| `sources` | Expected local stores/directories and an IPC socket exist. Presence does not prove compatible data or a functioning protocol. |
| `navigation` | A `codex://` handler is registered and whether it matches the configured desktop bundle. `taskOpening` stays `not-tested`; no URL is opened. |
| `cache` | Age of each field's source observation. Rewriting the cache cannot refresh an older quota or context timestamp. Runtime task state is not stored in this cache. |
| `taskOrder` | The saved `running-first` or `waiting-first` preference; missing/invalid settings use `running-first`. |
| `runtimeProbe`, `approvalDelivery` | Explicitly untested operations. Readiness must not be presented as successful navigation or approval delivery. |

Cache freshness uses `fresh`, `stale` (still eligible), `expired`, `missing`,
`undated`, or `invalid-timestamp`. Quota is fresh for 30 seconds and eligible for
15 minutes; cached context is eligible for 60 seconds, and model metadata for
300 seconds. A value more than five seconds in the future cannot be called fresh.
These are cache observations, not a live task-state health check.

The report omits prompts, responses, task/project IDs, titles, model names, quota
values, credentials, and local paths. It is different from `--status-output`, whose
private development snapshot includes task metadata and actual collection order.
Use the doctor report for an issue; keep raw status/session logs local.

## Complete an acceptance check

After inspecting readiness, run `bash scripts/test-release.sh --build` and use the
app from `release/test/`. Confirm that the running package reports the expected
version, then verify the affected behavior on hardware. The
[compatibility matrix](COMPATIBILITY.md) distinguishes these checks from unit tests,
cross-compilation, and translated execution.
