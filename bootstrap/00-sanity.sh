#!/usr/bin/env bash
# Prereq sanity check. Always runs. Logs kernel, bootc, and hardware state,
# then verifies critical tooling is present.
set -euo pipefail

# shellcheck source=/usr/share/bootstrap/lib/common.sh
source /usr/share/bootstrap/lib/common.sh
require_root

[[ "${1:-}" == "--check" ]] && exit 0

log "hostname: $(hostname)"
log "kernel:   $(uname -r)"

# bootc status parsing. Avoid fragile jq paths; use plain output.
if bootc_line=$(bootc status 2>/dev/null | awk '/Booted image:/ {print; exit}'); then
    log "bootc:    ${bootc_line:-unknown}"
else
    warn "bootc status unavailable (may be non-bootc system)"
fi

# Critical tools must be present on every run.
for tool in systemd-cryptenroll cryptsetup fwupdmgr; do
    command -v "$tool" >/dev/null || warn "missing: $tool"
done

# Hardware-dependent tools are optional outside Framework hardware.
for tool in tpm2_pcrread ykman fprintd-enroll framework_tool; do
    command -v "$tool" >/dev/null || skip "tool not present (OK outside Framework): $tool"
done

if is_framework_laptop; then
    ok "Framework Laptop detected"
    if ! has_tpm2; then
        err "TPM2 not functional - enable Intel PTT in BIOS"
    fi
    if framework_tool --versions >/dev/null 2>&1; then
        ok "framework_tool can talk to EC"
    else
        warn "framework_tool can't reach EC - check cros_ec kernel module"
    fi
elif is_vm; then
    skip "running in a VM - hardware checks deferred"
    if has_tpm2; then
        ok "TPM2 present (swtpm or passthrough)"
    fi
else
    warn "unknown hardware - proceeding with best-effort detection"
fi

marker_write "00-sanity"
