#!/usr/bin/env bash
# Pull latest firmware from LVFS and apply it. In VMs this is a no-op.
set -euo pipefail

# shellcheck source=/usr/share/bootstrap/lib/common.sh
source /usr/share/bootstrap/lib/common.sh
require_root

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

if is_vm; then
    skip "running in a VM - no real firmware to update"
    marker_write "05-firmware"
    exit 0
fi

fwupdmgr refresh --force >/dev/null 2>&1 || warn "fwupd refresh failed (no network?)"

PENDING=$(fwupdmgr get-updates 2>/dev/null | grep -c '^ •' || true)

if [[ $PENDING -eq 0 ]]; then
    ok "Firmware up to date"
    marker_write "05-firmware"
    exit 0
fi

if [[ $CHECK -eq 1 ]]; then
    warn "$PENDING firmware update(s) pending"
    exit 1
fi

log "Applying $PENDING firmware update(s). System may reboot."
fwupdmgr update -y --no-reboot-check || warn "some updates deferred to next boot"

marker_write "05-firmware"
