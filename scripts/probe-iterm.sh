#!/usr/bin/env bash
# probe-iterm.sh
# Run this from inside an iTerm tab. It prints the env-vars Factory hooks would
# inherit and the list of session UUIDs iTerm reports via AppleScript, so you
# can verify the mapping the focuser relies on.
#
#   $ITERM_SESSION_ID  ===  "w<window>t<tab>p<pane>:<UUID>"
#   AppleScript "unique id of session"  ===  "<UUID>"  (the bare UUID)

echo "ITERM_SESSION_ID = ${ITERM_SESSION_ID:-<unset>}"
echo "TERM_PROGRAM     = ${TERM_PROGRAM:-<unset>}"
echo

if [ -n "${ITERM_SESSION_ID:-}" ]; then
    bare="${ITERM_SESSION_ID#*:}"
    echo "Stripped UUID    = ${bare}"
    echo
fi

echo "Sessions iTerm currently knows about:"
osascript <<'APPLESCRIPT'
tell application "iTerm"
    set out to ""
    repeat with w in windows
        set wi to id of w
        repeat with t in tabs of w
            set ti to index of t
            repeat with s in sessions of t
                set sid to (unique id of s) as string
                set sn to (name of s) as string
                set out to out & "  win=" & wi & " tab=" & ti & " uuid=" & sid & "  name=" & sn & "\n"
            end repeat
        end repeat
    end repeat
    return out
end tell
APPLESCRIPT
