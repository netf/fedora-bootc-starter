#!/usr/bin/env bash
# Wipe the weak installer passphrase (keyslot 0) after TPM2, FIDO2, and recovery are enrolled.
set -euo pipefail

# shellcheck source=/usr/share/bootstrap/lib/common.sh
source /usr/share/bootstrap/lib/common.sh
require_root

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

if ! has_encrypted_root; then
    skip "root is not LUKS-encrypted - nothing to wipe"
    marker_write "13-wipe"
    exit 0
fi

DEV=$(luks_device)
DUMP=$(cryptsetup luksDump "$DEV")

if ! grep -qE '^\s*0:\s+luks2' <<<"$DUMP"; then
    ok "Installer passphrase already wiped"
    marker_write "13-wipe"
    exit 0
fi

if [[ $CHECK -eq 1 ]]; then
    warn "Installer passphrase still present"
    exit 1
fi

# Refuse to wipe unless all three escape hatches exist.
grep -q "systemd-tpm2"     <<<"$DUMP" || err "Refusing: TPM2 not enrolled"
grep -q "systemd-fido2"    <<<"$DUMP" || err "Refusing: FIDO2 not enrolled"
grep -q "systemd-recovery" <<<"$DUMP" || err "Refusing: recovery key not enrolled"

warn "Wiping keyslot 0 (installer passphrase) on $DEV"
read -rp "Type YES to proceed: " ans
[[ "$ans" == "YES" ]] || err "aborted"

cryptsetup luksKillSlot "$DEV" 0
ok "Installer passphrase wiped. Unlock is now TPM2 (auto) / YubiKey / recovery key only."
marker_write "13-wipe"
