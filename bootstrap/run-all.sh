#!/usr/bin/env bash
# Orchestrate every numbered bootstrap step in order. --check is a dry-run.
set -euo pipefail

# shellcheck source=/usr/share/bootstrap/lib/common.sh
source /usr/share/bootstrap/lib/common.sh
require_root

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

cd /usr/share/bootstrap
mapfile -t STEPS < <(find . -maxdepth 1 -name '[0-9]*.sh' -type f | sort)

if [[ ${#STEPS[@]} -eq 0 ]]; then
    err "no bootstrap steps found in $PWD"
fi

FAILED=0
for step in "${STEPS[@]}"; do
    name=${step#./}
    log "=== $name ==="
    if [[ $CHECK -eq 1 ]]; then
        if ! "$step" --check; then
            FAILED=1
            warn "$name needs running"
        fi
    else
        "$step"
    fi
done

if [[ $CHECK -eq 1 ]]; then
    if [[ $FAILED -eq 0 ]]; then
        ok "All steps idempotent - nothing to do"
    else
        exit 1
    fi
else
    marker_write "all"
    ok "Bootstrap complete. Reboot recommended."
fi
