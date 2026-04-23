#!/usr/bin/env bash
# Enroll FIDO2 (YubiKey) as a LUKS keyslot with PIN and user presence.
set -euo pipefail

# shellcheck source=/usr/share/bootstrap/lib/common.sh
source /usr/share/bootstrap/lib/common.sh
require_root

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

if ! has_encrypted_root; then
    skip "root is not LUKS-encrypted - FIDO2 enrollment N/A"
    marker_write "11-fido2"
    exit 0
fi
if ! has_yubikey; then
    skip "no YubiKey detected - plug one in and re-run if you want FIDO2"
    marker_write "11-fido2"
    exit 0
fi

DEV=$(luks_device)

if has_token "$DEV" "systemd-fido2"; then
    ok "FIDO2 already enrolled on $DEV"
    marker_write "11-fido2"
    exit 0
fi

if [[ $CHECK -eq 1 ]]; then
    warn "FIDO2 NOT enrolled"
    exit 1
fi

log "Enrolling FIDO2 on $DEV with PIN + user presence (touch the YubiKey when it blinks)"
systemd-cryptenroll "$DEV" \
    --fido2-device=auto \
    --fido2-with-client-pin=yes \
    --fido2-with-user-presence=yes

ok "FIDO2 enrolled"
marker_write "11-fido2"
