#!/usr/bin/env bash
# Generate a LUKS recovery key. This is the break-glass path if TPM2 and FIDO2 fail.
set -euo pipefail

# shellcheck source=/usr/share/bootstrap/lib/common.sh
source /usr/share/bootstrap/lib/common.sh
require_root

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

if ! has_encrypted_root; then
    skip "root is not LUKS-encrypted - recovery key N/A"
    marker_write "12-recovery"
    exit 0
fi

DEV=$(luks_device)

if has_token "$DEV" "systemd-recovery"; then
    ok "Recovery key already present on $DEV"
    marker_write "12-recovery"
    exit 0
fi

if [[ $CHECK -eq 1 ]]; then
    warn "Recovery key NOT enrolled"
    exit 1
fi

cat >&2 <<'EOF'

============================================================
  A LUKS recovery key will be generated and displayed ONCE.
  Write it on paper. Store it in a safe place OFFLINE.
  This is your only way in if TPM2 and YubiKey both fail.
============================================================

EOF
read -rp "Press enter when ready to see the key..."

systemd-cryptenroll "$DEV" --recovery-key

read -rp "Type 'saved' to confirm you wrote it down: " ans
[[ "$ans" == "saved" ]] || err "not confirmed - re-run to re-display"

clear
ok "Recovery key enrolled"
marker_write "12-recovery"
