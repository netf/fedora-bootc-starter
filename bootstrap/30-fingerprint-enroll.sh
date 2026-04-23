#!/usr/bin/env bash
# Framework 13 Pro: Goodix fingerprint reader integrated into the power button.
set -euo pipefail

# shellcheck source=/usr/share/bootstrap/lib/common.sh
source /usr/share/bootstrap/lib/common.sh

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

if ! has_fingerprint_reader; then
    skip "no fingerprint reader detected - skipping"
    marker_write "30-fprint"
    exit 0
fi

USER_NAME="${SUDO_USER:-netf}"

if sudo -u "$USER_NAME" fprintd-list "$USER_NAME" 2>/dev/null \
    | grep -q "right-index-finger\|left-index-finger"; then
    ok "Fingerprint already enrolled for $USER_NAME"
    marker_write "30-fprint"
    exit 0
fi

if [[ $CHECK -eq 1 ]]; then
    warn "No fingerprint enrolled"
    exit 1
fi

log "Enrolling right index finger for $USER_NAME"
log "Press the power button repeatedly until enrollment completes (5 reads)"
sudo -u "$USER_NAME" fprintd-enroll -f right-index-finger "$USER_NAME"

ok "Fingerprint enrolled"
marker_write "30-fprint"
