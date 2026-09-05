# Model display interface v1

This interface controls model and effort labels for every task source, including
Codex. It changes display text only: the raw `model`, `effort`, provider identity,
model selection, and cached evidence retain their original values. A label is not
a claim about a model's capabilities or availability.

- [JSON Schema](model-display-v1.schema.json) — document shape and field types.
- [Default rules and mapping tables](../../Resources/ModelDisplay.json) — the
  editable document shipped with the app; also the complete example to copy.
- [Foundation contract and formatter](../../Sources/AgentStatusCore/ModelDisplayConfiguration.swift)
  — `ModelDisplayConfiguration`, `ModelDisplayRules`, and `ModelDisplayFormatter`.

## Where to configure

Developers can edit `Resources/ModelDisplay.json` and rebuild. It is copied to
`RehireBar.app/Contents/Resources/ModelDisplay.json` before signing.

To customize an installed app without rebuilding, copy the default document from
this source checkout:

```bash
mkdir -p "$HOME/Library/Application Support/RehireBar"
cp -n Resources/ModelDisplay.json "$HOME/Library/Application Support/RehireBar/model-display.json"
```

Edit the copied file. Existing local settings are not overwritten by that command.
The local document replaces the complete bundled policy; it is not a partial patch.
Keep all required fields, using empty objects or arrays to disable mappings or
prefix removal. Use an atomic file replacement when updating it programmatically.

The presenter reads local configuration on its next status refresh. A manual quota
refresh also reloads it; restarting the app loads it at startup. Missing, malformed,
unsupported, oversized, or otherwise invalid local configuration falls back to the
bundled policy. If no valid bundled policy exists, raw model/effort labels are used.
Configuration files must be regular files, at most 64 KiB (65,536 bytes); symlinks
and special files are rejected. Do not symlink the containing directory.

## Matching and abbreviation order

For an available `model` value:

1. Trim surrounding whitespace for matching/display. Preserve the stored raw ID.
2. Match an exact model key in `providerModelAliases[providerID]`.
3. Match an exact model key in the global `modelAliases` table.
4. Remove the first matching prefix in the ordered `rules.stripPrefixes` array.
   Only one prefix is removed.
5. Split the remaining name on `-`. Replace its final component only if that
   component appears in `modelSuffixAliases`. Preserve every preceding component.
6. When a suffix matched and the remaining preceding part consists entirely of
   ASCII digits, append `rules.integerVersionSuffix` before the suffix alias.
   This is display formatting, not an inferred model version.
7. If no alias or known suffix matches, show the name after the configured prefix
   removal. Do not infer initials, remove unrecognized variants, or invent a model.

Exact aliases return directly and are not reformatted by later rules. Model keys,
prefixes, suffixes, and effort keys obey `rules.caseSensitive`; its default is
`false`. `providerID` always matches exactly, including case, consistent with the
task identity contract. Two aliases in the same table that differ only in case
are invalid when matching is case-insensitive.

## Rules

| Field | Shipped value | Meaning |
| --- | --- | --- |
| `caseSensitive` | `false` | Case sensitivity for model/effort matching. |
| `stripPrefixes` | `["gpt-"]` | Ordered prefixes eligible for one removal. Use `[]` to retain all prefixes. |
| `integerVersionSuffix` | `".0"` | Display suffix for a digit-only base after a known family matched. Use `""` to disable. |
| `uppercaseUnknownEffort` | `true` | Uppercase an effort value absent from `effortAliases`; `false` preserves its spelling. |
| `effortSeparator` | `"·"` | Separator used only when both model and effort are present. |

The Schema describes structural limits. The Swift validator additionally rejects
control characters, surrounding whitespace in configuration strings, empty prefix
entries, empty alias keys/values, ambiguous case-insensitive keys, and suffix keys
containing `-`. Optional empty strings are allowed only for `integerVersionSuffix`
and `effortSeparator`. Empty tables are valid.

## Shipped mapping tables

The JSON document is the source of truth. These tables describe its shipped values;
developers may replace them with their own names and conventions.

| Exact model key (case-insensitive) | Label |
| --- | --- |
| `gpt6-astra` | `6.0A` |
| `gpt-6-astra` | `6.0A` |

| Final model component | Suffix label |
| --- | --- |
| `astra` | `A` |
| `sol` | `S` |
| `terra` | `T` |
| `luna` | `L` |
| `mini` | `m` |

| Effort value | Label |
| --- | --- |
| `none` | `—` |
| `minimal` | `MIN` |
| `low` | `L` |
| `medium` | `M` |
| `high` | `H` |
| `xhigh` | `XH` |
| `max` | `MAX` |
| `ultra` | `ULT` |

Examples of formatting, not a supported-model catalog:

| Raw input | Shipped display |
| --- | --- |
| `GPT6-astra` | `6.0A` |
| `gpt-6-astra` | `6.0A` |
| `gpt-6.0-astra` | `6.0A` |
| `gpt-5.6-sol` | `5.6S` |
| `gpt-5.6-terra` | `5.6T` |
| `gpt-5.6-luna` | `5.6L` |
| `gpt-5.4-mini` | `5.4m` |
| `o4-mini` | `o4m` |
| `gpt-6.1-nova` | `6.1-nova` |
| `gpt-6-astra-pro` | `6-astra-pro` |
| `gpt-6-astra` + effort `xhigh` | `6.0A·XH` |

When `model` is absent, the entire model/effort label remains absent. An unknown
model retains its name under the configured prefix rule. An absent effort adds no
separator. The existing fast-mode indicator is independent of this configuration.

## Provider-specific labels

`providerModelAliases` is empty by default. To give one integration a distinct label,
set this field in the complete configuration document:

```json
"providerModelAliases": {
  "example-agent": {
    "org/custom-model": "Custom"
  }
}
```

This fragment is not a standalone file. Other providers are unaffected. Providers
continue to publish the raw model ID in their [Agent status document](AGENT-STATUS-INTERFACE.md);
they should not replace it with a display alias. The Touch Bar UI contains no
provider-specific model abbreviation tables.

## Validation and compatibility

`schemaVersion` is `1`; breaking rule semantics require a new version. Additive
unknown fields are ignored. Use `ModelDisplayConfiguration.decode(_:)` or
`validate()` to check a policy with the same rules as the app. The formatter is
Foundation-only and can be used independently of AppKit.

Tests cover alias precedence, provider isolation, case handling, custom rules,
unknown variants, missing model/effort, raw-ID preservation, local-file replacement,
invalid-file fallback, and propagation to rendered cards. Run the repository's
[required validation](../../AGENTS.md) after changing the defaults or implementation.
