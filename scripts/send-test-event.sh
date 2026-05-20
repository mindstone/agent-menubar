#!/usr/bin/env bash
# send-test-event.sh
#
# Send a fake Factory hook event to the running AgentMenuBar app's socket.
# Useful for development without firing up a real droid session.
#
# Usage:
#   ./scripts/send-test-event.sh                                # one Notification + one Stop demo
#   ./scripts/send-test-event.sh Notification SID CWD "msg"     # custom single event
#
# When inside iTerm, ITERM_SESSION_ID is auto-included so click-to-focus works.

set -u

SOCK="${HOME}/Library/Application Support/AgentMenuBar/sock"
if [ ! -S "${SOCK}" ]; then
    echo "ERROR: socket not found at ${SOCK}"
    echo "Is AgentMenuBar running? Try: make run"
    exit 1
fi

send() {
    local event="$1" sid="$2" cwd="$3" msg="$4" prompt="${5:-}"
    local payload
    payload="$(jq -nc \
        --arg event "${event}" \
        --arg sid   "${sid}" \
        --arg cwd   "${cwd}" \
        --arg msg   "${msg}" \
        --arg prompt "${prompt}" \
        --arg iterm "${ITERM_SESSION_ID:-}" \
        --arg term  "${TERM_PROGRAM:-}" \
        --arg ts    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            hook_event_name: $event,
            session_id:      $sid,
            cwd:             $cwd,
            message:         (if $msg    == "" then null else $msg    end),
            prompt:          (if $prompt == "" then null else $prompt end),
            transcript_path: null,
            iterm_session_id:$iterm,
            term_program:   $term,
            received_at:    $ts
        }')"
    echo ">> ${event}  ${sid}"
    echo "${payload}"
    echo "${payload}" | nc -U "${SOCK}" -w 1 || true
}

if [ "$#" -ge 4 ]; then
    send "$1" "$2" "$3" "$4" "${5:-}"
    exit 0
fi

# Demo mode
send "SessionStart"     "demo-1" "${PWD}" "" ""
sleep 1
send "UserPromptSubmit" "demo-1" "${PWD}" "" "Refactor the auth module to use OAuth"
sleep 1
send "Notification"     "demo-1" "${PWD}" "Should I run npm install before continuing?" ""
sleep 2
send "Stop"             "demo-1" "${PWD}" "" ""
echo "Done. Check the menu bar and notifications."
