#!/usr/bin/env bash
# Convenience wrapper that runs core then hardware profiles. --check is a dry-run.
set -euo pipefail

# shellcheck source=/usr/share/bootstrap/lib/common.sh
source /usr/share/bootstrap/lib/common.sh
require_root

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

FAILED=0
for profile in core hardware; do
    log "=== profile: $profile ==="
    if [[ $CHECK -eq 1 ]]; then
        if ! /usr/share/bootstrap/run-profile.sh "$profile" --check; then
            FAILED=1
        fi
    else
        /usr/share/bootstrap/run-profile.sh "$profile"
    fi
done

if [[ $CHECK -eq 1 ]]; then
    if [[ $FAILED -eq 0 ]]; then
        ok "All bootstrap profiles idempotent - nothing to do"
    else
        exit 1
    fi
else
    marker_write "all"
    ok "All bootstrap profiles completed. Reboot recommended."
fi
