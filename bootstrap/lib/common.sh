#!/usr/bin/env bash
# Shared helpers for first-boot bootstrap scripts.
# Sourced by every bootstrap/NN-*.sh; do not exec or exit on source.
set -euo pipefail

log()  { printf '\e[1;34m[bootstrap]\e[0m %s\n' "$*" >&2; }
ok()   { printf '\e[1;32m[   ok   ]\e[0m %s\n' "$*" >&2; }
warn() { printf '\e[1;33m[  warn  ]\e[0m %s\n' "$*" >&2; }
skip() { printf '\e[1;36m[  skip  ]\e[0m %s\n' "$*" >&2; }
err()  { printf '\e[1;31m[  fail  ]\e[0m %s\n' "$*" >&2; exit 2; }

require_root() {
    [[ $EUID -eq 0 ]] || err "must run as root"
}

# Hardware detection.
# Return 0 if applicable, 1 if not. Scripts use these to skip gracefully.
is_framework_laptop() {
    [[ "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)" == "Framework" ]]
}

is_vm() {
    local vendor
    vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "")
    [[ "$vendor" =~ (QEMU|KVM|innotek|VMware|Xen|Microsoft\ Corporation) ]]
}

has_tpm2() {
    [[ -e /dev/tpm0 || -e /dev/tpmrm0 ]] \
        && command -v tpm2_pcrread >/dev/null 2>&1 \
        && tpm2_pcrread sha256:7 >/dev/null 2>&1
}

has_yubikey() {
    command -v ykman >/dev/null 2>&1 && [[ -n "$(ykman list 2>/dev/null)" ]]
}

has_fingerprint_reader() {
    lsusb 2>/dev/null | grep -iqE "goodix|synaptics.*fingerprint|validity"
}

has_encrypted_root() {
    findmnt -no SOURCE / 2>/dev/null | grep -q "^/dev/mapper/luks-"
}

# LUKS helpers.
luks_device() {
    local mapper
    mapper=$(findmnt -no SOURCE / | sed 's,.*/,,')
    cryptsetup status "$mapper" | awk '/device:/ {print $2}'
}

crypt_mapper_name() {
    findmnt -no SOURCE / | sed 's,.*/,,'
}

has_token() {
    local dev="$1" token="$2"
    cryptsetup luksDump "$dev" | grep -q "$token"
}

# Marker files for per-step idempotency.
marker_write() { mkdir -p /var/lib/bootstrap && touch "/var/lib/bootstrap/.${1}.done"; }

# Marker files for boot-critical changes that require initramfs regeneration.
boot_artifacts_dirty() { [[ -f /var/lib/bootstrap/.boot-artifacts-dirty ]]; }
mark_boot_artifacts_dirty() { mkdir -p /var/lib/bootstrap && touch /var/lib/bootstrap/.boot-artifacts-dirty; }
clear_boot_artifacts_dirty() { rm -f /var/lib/bootstrap/.boot-artifacts-dirty; }
