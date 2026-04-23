#!/usr/bin/env bash
# Enroll TPM2 as a LUKS keyslot bound to PCR 7 (secure boot) and 11 (kernel/initrd).
set -euo pipefail

# shellcheck source=/usr/share/bootstrap/lib/common.sh
source /usr/share/bootstrap/lib/common.sh
require_root

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

if ! has_encrypted_root; then
    skip "root is not LUKS-encrypted - TPM2 enrollment N/A"
    marker_write "10-tpm2"
    exit 0
fi
if ! has_tpm2; then
    skip "no functional TPM2 on this machine - skipping enrollment"
    marker_write "10-tpm2"
    exit 0
fi

DEV=$(luks_device)
MAPPER=$(crypt_mapper_name)

if has_token "$DEV" "systemd-tpm2"; then
    ok "TPM2 already enrolled on $DEV"
    marker_write "10-tpm2"
    exit 0
fi

if [[ $CHECK -eq 1 ]]; then
    warn "TPM2 NOT enrolled on $DEV"
    exit 1
fi

log "Enrolling TPM2 on $DEV (PCRs 7+11). Prompts for current LUKS passphrase."
systemd-cryptenroll "$DEV" --tpm2-device=auto --tpm2-pcrs=7+11

if ! grep -qE "^${MAPPER}.*tpm2-device=auto" /etc/crypttab; then
    log "Patching /etc/crypttab for TPM2 auto-unlock"
    sed -ri "s|^(${MAPPER}\s+\S+\s+\S+)(\s+.*)?$|\1 tpm2-device=auto|" /etc/crypttab
fi

ok "TPM2 enrolled"
marker_write "10-tpm2"
