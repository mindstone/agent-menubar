#!/usr/bin/env bash
# factory-event-bridge.sh
#
# Single hook script registered for every Factory hook event we care about.
# Reads Factory's JSON payload from stdin, augments it with terminal session
# identifiers (iTerm + Ghostty) and other env signals, and forwards it to
# AgentMenuBar.app via a Unix domain socket. Also appends to a debug log so
# events survive when the app is not running.
#
# Must NEVER block droid: any failure exits 0 with no output.

set -u

LOG_DIR="${HOME}/Library/Logs/AgentMenuBar"
SOCK="${HOME}/Library/Application Support/AgentMenuBar/sock"
LOG_FILE="${LOG_DIR}/events.log"

mkdir -p "${LOG_DIR}" 2>/dev/null || true

# Read the Factory payload (single JSON object) from stdin.
payload="$(cat)"

# Augment with iTerm + env signals. Use jq if present, otherwise minimal awk-style merge.
if command -v jq >/dev/null 2>&1; then
    augmented="$(printf '%s' "${payload}" | jq -c \
        --arg iterm   "${ITERM_SESSION_ID:-}" \
        --arg ghostty "${GHOSTTY_SURFACE_ID:-}" \
        --arg term    "${TERM_PROGRAM:-}" \
        --arg ppid    "${PPID:-0}" \
        --arg ts      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '. + {
            iterm_session_id:   $iterm,
            ghostty_surface_id: $ghostty,
            term_program:       $term,
            ppid:               ($ppid | tonumber? // 0),
            received_at:        $ts
        }' 2>/dev/null)"
else
    # Best-effort fallback: prepend signals as a sibling JSON object on a separate line.
    augmented="${payload}"
fi

[ -z "${augmented}" ] && augmented="${payload}"

# Always log (one event per line) so we can debug even when the app is off.
printf '%s\n' "${augmented}" >> "${LOG_FILE}" 2>/dev/null || true

# Try to forward to the running app. Quiet failure on purpose.
if [ -S "${SOCK}" ]; then
    printf '%s\n' "${augmented}" | /usr/bin/nc -U "${SOCK}" -w 1 >/dev/null 2>&1 || true
fi

exit 0
