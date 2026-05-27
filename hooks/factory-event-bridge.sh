#!/usr/bin/env bash
# Thin Factory Droid hook wrapper. Keep Factory-specific registration pointed
# here; all payload normalization happens in agent-event-bridge.sh.

set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${DIR}/agent-event-bridge.sh" factory-droid
