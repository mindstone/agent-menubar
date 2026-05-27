#!/usr/bin/env bash
# agent-event-bridge.sh
#
# Common hook bridge for agent CLIs. Reads one JSON hook payload from stdin,
# tags it with the source agent, augments it with terminal identifiers, logs it,
# and forwards it to AgentMenuBar.app over a Unix domain socket.
#
# Must NEVER block the agent: any failure exits 0 with no output.

set -u

AGENT_KIND="${1:-unknown}"
LOG_DIR="${HOME}/Library/Logs/AgentMenuBar"
SOCK="${HOME}/Library/Application Support/AgentMenuBar/sock"
LOG_FILE="${LOG_DIR}/events.log"

mkdir -p "${LOG_DIR}" 2>/dev/null || true

payload="$(cat)"

if command -v jq >/dev/null 2>&1; then
    augmented="$(printf '%s' "${payload}" | jq -c \
        --arg agent   "${AGENT_KIND}" \
        --arg iterm   "${ITERM_SESSION_ID:-}" \
        --arg ghostty "${GHOSTTY_SURFACE_ID:-}" \
        --arg term    "${TERM_PROGRAM:-}" \
        --arg ppid    "${PPID:-0}" \
        --arg ts      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '. as $in
         | . + {
            agent_kind:        $agent,
            iterm_session_id:  $iterm,
            ghostty_surface_id:$ghostty,
            term_program:      $term,
            ppid:              ($ppid | tonumber? // 0),
            received_at:       $ts
         }
         | if ((.message // "") == "") then
             .message = (($in.tool_input.description? // $in.last_assistant_message? // "") | tostring)
           else
             .
           end' 2>/dev/null)"
else
    augmented="${payload}"
fi

[ -z "${augmented}" ] && augmented="${payload}"

printf '%s\n' "${augmented}" >> "${LOG_FILE}" 2>/dev/null || true

if [ -S "${SOCK}" ]; then
    printf '%s\n' "${augmented}" | /usr/bin/nc -U "${SOCK}" -w 1 >/dev/null 2>&1 || true
fi

exit 0
