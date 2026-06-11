#!/usr/bin/env bash
# Thin Claude Code (claude) hook wrapper. Claude Code's stdin payload already
# uses the field names HookEvent understands (session_id, cwd, transcript_path,
# hook_event_name, message, prompt, source, tool_name), so the shared bridge
# can handle it directly — it just adds terminal/session metadata and forwards
# to the menu bar app.

set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${DIR}/agent-event-bridge.sh" claude-code
