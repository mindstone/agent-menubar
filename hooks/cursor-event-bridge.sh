#!/usr/bin/env bash
# Cursor CLI (cursor-agent) hook wrapper.
#
# Cursor's hook payloads differ from Factory/Codex: the stable session id is
# `conversation_id` (not `session_id`), the working directory is exposed as
# `workspace_roots[]` (not `cwd`) on lifecycle events, and the user prompt
# arrives as `prompt`. We normalise those into the shared field names the
# common bridge and HookEvent already understand, then hand off. The shared
# bridge adds terminal/session metadata and forwards to the menu bar app.
#
# Must NEVER block the agent: any failure still pipes the original payload
# through and the shared bridge exits 0.

set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

payload="$(cat)"

if command -v jq >/dev/null 2>&1; then
    normalized="$(printf '%s' "${payload}" | jq -c '
        . + {
            session_id: (.session_id // .conversation_id // "cursor-unknown"),
            cwd:        (.cwd // (.workspace_roots[0]?) // null),
            prompt:     (.prompt // .text // null),
            message:    (.message // .command // null)
        }' 2>/dev/null)"
    [ -n "${normalized}" ] && payload="${normalized}"
fi

printf '%s' "${payload}" | "${DIR}/agent-event-bridge.sh" cursor
