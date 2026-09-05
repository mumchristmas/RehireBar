# Security policy

## Supported version

Security fixes are applied to the latest code on the default branch.

## Report a vulnerability

Please use the repository's private **Security advisories** reporting flow. Do not open a public issue for a vulnerability or include credentials, raw session logs, prompts, responses, or thread identifiers in a report.

Include a minimal reproduction, affected macOS and Codex versions, and the security impact. Sanitize all local paths and identifiers.

## Trust boundaries

RehireBar is a local helper. It reads bounded local Codex status/session metadata and communicates with local Codex processes. It is not designed to accept network connections. Task navigation validates the target thread UUID, and approval delivery fails closed unless the local Codex Desktop endpoint confirms the exact thread.

Custom Agent status files are local inputs: each JSON document is limited to 1 MiB. The reader pins its directory and file descriptors, rejects symlinks and non-regular files, and isolates invalid documents. Provider URLs are opened only after a task tap; install integrations you trust.
