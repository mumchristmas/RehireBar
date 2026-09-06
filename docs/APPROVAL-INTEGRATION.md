# Approval integration

Approval buttons are an explicit integration surface. RehireBar never treats ordinary prose as authority to act.

These buttons do not automatically intercept every Codex permission request.
The source agent must explicitly register a question using the command below.
Delivery remains conditional on the installed desktop version; see
[Compatibility](COMPATIBILITY.md).

## Register a decision gate

Call the installed executable with a valid Codex thread UUID and a short question:

```bash
APP='/Applications/RehireBar.app/Contents/MacOS/RehireBar'
"$APP" approval-request \
  --thread-id '019f56ad-6af2-7163-8771-cf8c5169e9d0' \
  --question 'Approve this design and continue?'
```

On success, the command prints the generated approval ID and exits with status `0`. Invalid input exits with status `2`.

## Agent rule example

An agent integration can use this policy:

> When a genuine decision gate requires user approval and the current Codex thread UUID is known, call `approval-request` before yielding the same question in chat. Failure to register the Touch Bar request must never hide or suppress the chat question. Do not register informational sentences, rhetorical questions, or decisions the agent is already authorized to make.

The chat question remains the canonical fallback. The Touch Bar is an additional input surface.

## Safety contract

- Thread IDs must be valid UUIDs.
- Empty or oversized questions are rejected.
- Requests expire within 24 hours.
- The queue is bounded and written atomically under the user's Application Support directory.
- A Touch Bar response is considered delivered only when the local Codex Desktop endpoint confirms the exact source thread.
- Rejected, timed-out, and protocol-mismatched responses remain visibly unsent and retryable.

## Compatibility

Response delivery uses a local, versioned Codex Desktop IPC route. If a Codex Desktop update changes that route, approval registration can still display locally, but delivery will fail closed until this project is updated.
