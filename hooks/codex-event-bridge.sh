#!/usr/bin/env bash
# Thin Codex CLI hook wrapper. Codex supplies hook JSON on stdin; the common
# bridge adds terminal/session metadata and forwards it to the menu bar app.

set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${DIR}/agent-event-bridge.sh" codex
