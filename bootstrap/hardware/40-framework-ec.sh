#!/usr/bin/env bash
# Set Framework EC defaults via framework_tool. Charge limit 80% for battery longevity.
set -euo pipefail

# shellcheck source=/usr/share/bootstrap/lib/common.sh
source /usr/share/bootstrap/lib/common.sh
require_root

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

if ! is_framework_laptop; then
    skip "not a Framework laptop - skipping EC config"
    marker_write "40-ec"
    exit 0
fi

if ! command -v framework_tool >/dev/null 2>&1; then
    err "is Framework laptop but framework_tool missing - image bug"
fi

CHARGE_LIMIT=80

CURRENT=$(framework_tool --charge-limit 2>/dev/null \
    | awk '/Maximum/ {print $NF}' | tr -d '%') || CURRENT=0

if [[ "$CURRENT" == "$CHARGE_LIMIT" ]]; then
    ok "Charge limit already set to ${CHARGE_LIMIT}%"
    marker_write "40-ec"
    exit 0
fi

if [[ $CHECK -eq 1 ]]; then
    warn "charge limit is ${CURRENT}%, want ${CHARGE_LIMIT}%"
    exit 1
fi

log "Setting battery charge limit to ${CHARGE_LIMIT}%"
framework_tool --charge-limit "$CHARGE_LIMIT"

ok "EC configured"
marker_write "40-ec"
