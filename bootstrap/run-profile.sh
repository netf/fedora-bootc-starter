#!/usr/bin/env bash
# Run a named bootstrap profile in order. --check is a dry-run.
set -euo pipefail

# shellcheck source=/usr/share/bootstrap/lib/common.sh
source /usr/share/bootstrap/lib/common.sh
require_root

PROFILE="${1:?profile required}"
CHECK=0
[[ "${2:-}" == "--check" ]] && CHECK=1

case "$PROFILE" in
    core)
        STEP_DIR=/usr/share/bootstrap/core
        ;;
    hardware)
        STEP_DIR=/usr/share/bootstrap/hardware
        ;;
    *)
        err "unknown bootstrap profile: $PROFILE"
        ;;
esac

mapfile -t STEPS < <(find "$STEP_DIR" -maxdepth 1 -name '[0-9]*.sh' -type f | sort)
BOOT_ARTIFACTS_DIRTY=0

if [[ ${#STEPS[@]} -eq 0 ]]; then
    err "no bootstrap steps found in $STEP_DIR"
fi

FAILED=0
for step in "${STEPS[@]}"; do
    name=${step##*/}
    log "=== ${PROFILE}/${name} ==="
    if [[ $CHECK -eq 1 ]]; then
        if ! bash "$step" --check; then
            FAILED=1
            warn "${PROFILE}/${name} needs running"
        fi
    else
        bash "$step"
    fi
done

if [[ "$PROFILE" == "core" ]] && boot_artifacts_dirty; then
    BOOT_ARTIFACTS_DIRTY=1
fi

if [[ $CHECK -eq 1 ]]; then
    if [[ $BOOT_ARTIFACTS_DIRTY -eq 1 ]]; then
        FAILED=1
        warn "core boot artifacts dirty; initramfs rebuild pending"
    fi

    if [[ $FAILED -eq 0 ]]; then
        ok "Profile '$PROFILE' idempotent - nothing to do"
    else
        exit 1
    fi
else
    if [[ $BOOT_ARTIFACTS_DIRTY -eq 1 ]]; then
        kver=$(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort -V | tail -1)
        log "boot-critical state changed; regenerating initramfs for $kver"
        env DRACUT_NO_XATTR=1 dracut -vf "/usr/lib/modules/$kver/initramfs.img" "$kver"
        clear_boot_artifacts_dirty
        mkdir -p /var/lib/bootstrap
        touch /var/lib/bootstrap/.reboot-required
        warn "boot artifacts regenerated; reboot required"
    fi
    marker_write "$PROFILE"
    ok "Bootstrap profile '$PROFILE' complete."
fi
