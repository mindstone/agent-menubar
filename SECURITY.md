# Security policy

## Supported versions

AgentMenuBar is pre-1.0. Only the current `main` branch is supported. Older tags
will not receive security fixes — pull the latest and re-run `make install`.

## Reporting a vulnerability

Please **do not** open a public issue for security problems. Email the maintainer
directly:

- harrybloom18@gmail.com

Include reproduction steps, the affected commit hash, and (if applicable) a
proof-of-concept. You can expect an acknowledgement within 72 hours. I'll
coordinate a fix with you privately and credit you in the release notes once
it ships, unless you ask otherwise.

## What this app does and doesn't do

Designed scope:

- Runs entirely in your user space — no privileged install, no kernel extension.
- **Makes no network calls.** No telemetry, analytics, crash reporting, or
  update checks. All hook events stay on your machine.
- Reads and writes only inside your home directory:
  - `~/Library/Application Support/AgentMenuBar/` (session store, Unix socket)
  - `~/Library/Logs/AgentMenuBar/` (debug log of hook payloads)
  - `~/.factory/settings.json` (the `install-hooks` target adds a single hook
    entry per Factory event, with a timestamped backup of the prior file)
- Talks to iTerm2 via AppleScript using the standard macOS Automation +
  Accessibility permission grants. You must explicitly approve those prompts the
  first time you use them.
- Logs every received hook payload to `~/Library/Logs/AgentMenuBar/events.log`.
  These payloads include your droid prompts and the trailing text of model
  replies. If you're sharing your machine or your `~/Library/Logs` directory,
  treat the file accordingly.

Out of scope / known limitations:

- The Unix socket is `chmod 0600` so only your user can write to it, but the
  app does not authenticate the sender beyond that. Any process running as
  your user can send synthetic hook events.
- The bridge script is registered as a Factory hook and runs whenever Factory
  invokes its hook system. It is a thin shell script with no network calls;
  read `hooks/factory-event-bridge.sh` to verify.

## What contributors should be aware of

The following paths carry execution authority and require explicit code-owner
review (see `.github/CODEOWNERS`):

- `hooks/factory-event-bridge.sh` — runs whenever Factory fires a hook
- `Sources/AgentMenuBar/Focus/` — issues AppleScript against iTerm + System Events
- `Sources/AgentMenuBar/IPC/` — the socket server, trust boundary
- `Makefile` (especially `install-hooks` and `install`) — mutates settings.json
  and writes into `/Applications`
- `.github/workflows/` — run with repo secrets
- `Package.swift` — gateway for any third-party Swift dependency

When touching any of these, prefer not adding new third-party dependencies, not
adding network calls, and not running attacker-influenced strings through shell
interpolation, AppleScript interpolation, or `eval`-like constructs.
