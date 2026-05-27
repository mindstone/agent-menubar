# Adding a New CLI Agent

This document is the integration runbook for adding another coding CLI to AgentMenuBar. Use it when a future agent needs support beyond Factory Droid and Codex CLI.

The rule of thumb: keep each agent integration as a thin adapter. Do not push CLI-specific branches into the UI, socket server, terminal focus code, or persistence layer unless the shared event model genuinely needs a new field.

## Current Shape

AgentMenuBar has three layers for CLI support:

1. Hook wrapper: one script per CLI, for example `hooks/codex-event-bridge.sh`.
2. Common bridge: `hooks/agent-event-bridge.sh`, which adds `agent_kind`, terminal metadata, logging, and socket forwarding.
3. Swift adapter: one `AgentEventAdapter` implementation that maps the CLI's hook events to `SessionStatus`.

Terminal focus is separate. If the new CLI runs inside iTerm or Ghostty, the existing terminal capture may be enough. If it runs somewhere else, add terminal inventory/focus support separately under `Sources/AgentMenuBar/Focus/`.

## Non-Negotiables

- Use official documentation for the target CLI's hook system. Prefer vendor docs, vendor GitHub docs, or generated schemas from the vendor repo.
- Cite the official docs in the PR or implementation note.
- Verify every registered hook actually fires after implementation. Do not stop at "config file looks right".
- Keep the hook script non-blocking. The bridge must exit `0` and stay quiet even when AgentMenuBar is not running.
- Preserve the adapter boundary. CLI event names and payload quirks belong in `AgentEventAdapter` and the CLI hook wrapper, not in SwiftUI views.
- Keep uninstall idempotent. Any hook added by `install-*` must be removed by the matching `uninstall-*`.

## Research Checklist

Before editing code, answer these from official docs:

| Question | Why it matters |
|---|---|
| Where does the CLI load hook config from? | Determines the install target and whether user, repo, or global config is appropriate. |
| What hook events exist? | Determines the adapter state machine. |
| Which events are session-scoped vs turn-scoped? | Prevents treating "turn done" as "process ended". |
| What JSON fields are sent on stdin? | Determines whether `HookEvent` needs new decoded fields. |
| Which event means "waiting for the user"? | Drives orange menu-bar state. |
| Which event means "the user answered or the tool completed"? | Drives return to blue running state. |
| Which event means "idle/done for now"? | Drives green done state. |
| Are hooks trusted, reviewed, cached, or snapshotted? | Determines setup instructions and restart requirements. |
| Are matchers regexes, literals, or unsupported for some events? | Prevents hooks silently not firing. |
| Can multiple hooks run concurrently? | Affects assumptions about ordering and side effects. |

If the official docs do not define hooks, do not invent screen scraping or terminal parsing as a substitute. Document the blocker instead.

## Reusable Agent Prompts

Use these prompts with a coding agent when adding a new CLI.

### Research Prompt

```text
Research official documentation for <CLI_NAME>'s hook or lifecycle event system.
Use only official vendor docs, official schemas, or the vendor's source repository.
Return:
- hook config file locations
- hook event names
- stdin JSON fields for each event we need
- which events mean running, waiting for user, user/tool completed, and turn/session done
- any trust/review/restart behavior
- citations/links to the official sources
Do not propose implementation until the hook lifecycle is clear.
```

### Implementation Prompt

```text
Add <CLI_NAME> support to AgentMenuBar using the existing adapter architecture.
Keep CLI-specific logic in:
- hooks/<cli>-event-bridge.sh
- AgentKind
- AgentEventAdapter
- Makefile install/uninstall targets
- docs/reference snippets if useful

Do not move status logic into SwiftUI.
Do not add dependencies unless unavoidable.
Preserve Factory Droid and Codex behavior.
Update README and docs/adding-new-cli.md if the integration changes the process.
```

### Verification Prompt

```text
Test the <CLI_NAME> integration end to end.
Run the app, install hooks, perform any required hook trust/review step, then verify every registered hook fires.
For each hook:
- show the event in ~/Library/Logs/AgentMenuBar/events.log
- show the expected persisted state in ~/Library/Application Support/AgentMenuBar/sessions.json
- verify status transitions in order: running -> waitingForInput -> running -> finished where the CLI supports those states
Run swift build and git diff --check.
Report any hook that cannot be triggered with a reason.
```

## Implementation Steps

### 1. Add an Agent Kind

Edit `Sources/AgentMenuBar/Domain/AgentKind.swift`.

Add a stable raw value:

```swift
case exampleCli = "example-cli"
```

Add a short `displayName`. Keep it compact because it appears as a row pill in the popover.

### 2. Add a Hook Wrapper

Create a thin wrapper under `hooks/`:

```bash
#!/usr/bin/env bash
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${DIR}/agent-event-bridge.sh" example-cli
```

The wrapper should not parse the full payload unless the CLI requires pre-normalization before the shared bridge can handle it.

The shared bridge already:

- reads JSON from stdin
- adds `agent_kind`
- captures `ITERM_SESSION_ID`, `GHOSTTY_SURFACE_ID`, `TERM_PROGRAM`, `PPID`, and `received_at`
- appends to `~/Library/Logs/AgentMenuBar/events.log`
- forwards to `~/Library/Application Support/AgentMenuBar/sock`

If the new CLI uses different field names, prefer normalizing them in the wrapper or extending `HookEvent` decoding carefully.

### 3. Decode Any New Fields

Edit `Sources/AgentMenuBar/Domain/HookEvent.swift` only for fields that the adapter needs.

Before adding a field, check whether an existing field already covers the use case:

- `hookEventName`
- `sessionId`
- `cwd`
- `transcriptPath`
- `message`
- `prompt`
- `source`
- `toolName`
- `lastAssistantMessage`
- `permissionMode`
- `turnId`
- terminal metadata fields

Keep decoding tolerant. Hook payloads can differ by CLI version.

### 4. Add an Adapter

Edit `Sources/AgentMenuBar/Domain/AgentEventAdapter.swift`.

Add a new adapter and register it in `AgentEventAdapters.adapter(for:)`.

Map the CLI's events to these statuses:

| SessionStatus | Meaning |
|---|---|
| `.running` | The agent is actively working or has received a new prompt. |
| `.waitingForInput` | The user must answer, approve, choose, or intervene. |
| `.finished` | The current turn/task is idle or done from the user's point of view. |
| `.stale` | Reconciliation state for old loaded sessions, not usually set by hooks. |

Be explicit about turn-scoped events. For example, Codex and Factory Droid both use `Stop` as "turn done", so the UI shows green `DONE`; a later `UserPromptSubmit` flips the row back to blue.

### 5. Add Install and Uninstall Targets

Edit `Makefile`.

Add:

- `CLI_HOOK := $(REPO)/hooks/<cli>-event-bridge.sh`
- `CLI_SETTINGS := <official hook config path>`
- `install-<cli>-hooks`
- `uninstall-<cli>-hooks`

Also decide whether `make install-hooks` should include the new CLI by default. If the config file is user-global and harmless when the CLI is absent, include it. If installing requires a project-local trust step or changes a repo, consider a separate target only.

The install target must:

- `chmod +x` the wrapper and shared bridge
- create the settings directory/file if appropriate
- back up the existing config with a timestamp
- remove any previous entry for this bridge command before adding a new one
- add all hook events required by the adapter

The uninstall target must remove every event the install target added.

### 6. Add Reference Snippets

If useful, add `hooks/<cli>-hooks-block.json` or another doc snippet that mirrors the install target.

This is not a substitute for the Makefile target. The Makefile remains the source of truth for local install/uninstall behavior.

### 7. Update Docs

Update `README.md`:

- add the CLI to `Supported CLIs`
- list hook source path
- list waiting/done events
- document trust/restart requirements
- update known limits if needed

Update `AGENTS.md` if the integration changes architectural constraints or the dev loop.

## Acceptance Tests

Run all tests below before calling the integration done.

### Build and Static Checks

```bash
swift build
git diff --check
```

### Hook Config Check

Run the install target:

```bash
make install-<cli>-hooks
```

Then inspect the official config file and confirm every expected event is present. Use structured tools where possible:

```bash
jq '.hooks | keys' <config-file>
```

If the CLI requires trust/review, perform that step now.

### Bridge Shape Check

Send one representative event through the wrapper and confirm the log line contains:

- `agent_kind`
- `hook_event_name`
- `session_id`
- `cwd`
- terminal metadata when launched from a supported terminal

Example:

```bash
printf '%s\n' '{"hook_event_name":"UserPromptSubmit","session_id":"manual-test","cwd":"'"$PWD"'","prompt":"Manual hook test"}' \
  | hooks/<cli>-event-bridge.sh

tail -n 1 "$HOME/Library/Logs/AgentMenuBar/events.log"
```

### App Ingestion Check

Make sure the app is running and the socket exists:

```bash
test -S "$HOME/Library/Application Support/AgentMenuBar/sock"
```

Send the event sequence that matches the CLI lifecycle. Then inspect persistence:

```bash
jq '.[] | select(.id == "manual-test") | {id, agentKind, status, lastEvent, firstPrompt}' \
  "$HOME/Library/Application Support/AgentMenuBar/sessions.json"
```

Expected state sequence for a typical prompt-driven CLI:

1. Start or prompt event creates/updates a row as `running`.
2. Approval/question event changes it to `waitingForInput`.
3. Answer/tool-complete event changes it back to `running`.
4. Stop/done event changes it to `finished`.

If the CLI lacks one of these states, document that in the README.

### Real CLI Check

Manual bridge events are not enough. Start the actual CLI in a supported terminal and trigger every registered hook:

- new session/start event
- user prompt event
- waiting/approval/question event
- answer/tool-complete event if available
- stop/done event

For each event, confirm:

- a line appears in `~/Library/Logs/AgentMenuBar/events.log`
- the row in `sessions.json` has the expected `agentKind`
- the popover state matches the expected status

If a hook is difficult to trigger, include the exact reason in the final report.

## Final Report Template

Use this shape when handing off the integration:

```text
Added <CLI_NAME> support.

Official docs used:
- <link>

Hook mapping:
- <event> -> running
- <event> -> waitingForInput
- <event> -> running
- <event> -> finished

Files changed:
- hooks/<cli>-event-bridge.sh
- Sources/AgentMenuBar/Domain/AgentKind.swift
- Sources/AgentMenuBar/Domain/AgentEventAdapter.swift
- Makefile
- README.md

Verification:
- swift build: pass
- git diff --check: pass
- install hook config keys: <list>
- real CLI hooks observed: <list>
- manual lifecycle test: pass/fail

Manual follow-up:
- <trust/restart/login item/TCC note if any>
```

## Common Failure Modes

| Symptom | Likely cause | Check |
|---|---|---|
| No event in `events.log` | CLI did not load or trust the hook | Inspect official hook config and trust UI/command. |
| Event in log but no row | App is not running or socket forwarding failed | Check socket path and app process. |
| Row appears but is unclickable | No supported terminal id captured | Check `iterm_session_id`, `ghostty_surface_id`, and `term_program` in log. |
| Row stays blue during approval | Waiting event not registered or adapter does not map it | Check hook docs and `AgentEventAdapter`. |
| Row stays orange after approval | Completion event missing or not mapped back to running | Register/map the tool-complete or answer event. |
| Multiple historical rows appear | Terminal inventory did not collapse them | Use `store.visibleSessions`; do not filter in views. |

