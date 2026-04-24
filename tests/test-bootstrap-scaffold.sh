#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

test_netf_bootstrap_service() {
    local expected
    expected="$(cat <<'EOF'
[Unit]
Description=Piotr first-boot core bootstrap (LUKS enrollment, recovery, firmware)
After=systemd-user-sessions.service network-online.target
Wants=network-online.target
ConditionPathExists=!/var/lib/bootstrap/.core.done

[Service]
Type=oneshot
ExecStart=/usr/share/bootstrap/run-profile.sh core
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF
)"

    assert_file_matches "$REPO_ROOT/files/usr/lib/systemd/system/netf-bootstrap.service" "$expected"
}

test_profile_layout() {
    [[ -d "$REPO_ROOT/bootstrap/core" ]] || fail "missing directory: $REPO_ROOT/bootstrap/core"
    [[ -d "$REPO_ROOT/bootstrap/hardware" ]] || fail "missing directory: $REPO_ROOT/bootstrap/hardware"

    # Numbered scripts live under core/ or hardware/; no top-level shims.
    local shim
    for shim in "$REPO_ROOT"/bootstrap/[0-9]*.sh; do
        [[ -e "$shim" ]] && fail "shim reintroduced: $shim (move content into core/ or hardware/)"
    done
    return 0
}

test_common_library() {
    local path="$REPO_ROOT/bootstrap/lib/common.sh"

    assert_file_contains "$path" "set -euo pipefail"
    assert_file_contains "$path" "log()  { printf '\\e[1;34m[bootstrap]\\e[0m %s\\n' \"\$*\" >&2; }"
    assert_file_contains "$path" "require_root() {"
    assert_file_contains "$path" "is_framework_laptop() {"
    assert_file_contains "$path" "is_vm() {"
    assert_file_contains "$path" "has_tpm2() {"
    assert_file_contains "$path" "has_yubikey() {"
    assert_file_contains "$path" "has_fingerprint_reader() {"
    assert_file_contains "$path" "has_encrypted_root() {"
    assert_file_contains "$path" "luks_device() {"
    assert_file_contains "$path" "crypt_mapper_name() {"
    assert_file_contains "$path" "has_token() {"
    assert_file_contains "$path" "marker_write() { mkdir -p /var/lib/bootstrap && touch \"/var/lib/bootstrap/.\${1}.done\"; }"
    assert_file_contains "$path" "boot_artifacts_dirty() { [[ -f /var/lib/bootstrap/.boot-artifacts-dirty ]]; }"
    assert_file_contains "$path" "mark_boot_artifacts_dirty() { mkdir -p /var/lib/bootstrap && touch /var/lib/bootstrap/.boot-artifacts-dirty; }"
    assert_file_contains "$path" "clear_boot_artifacts_dirty() { rm -f /var/lib/bootstrap/.boot-artifacts-dirty; }"
}

test_sanity_script() {
    local path="$REPO_ROOT/bootstrap/core/00-sanity.sh"

    assert_file_contains "$path" "source /usr/share/bootstrap/lib/common.sh"
    assert_file_contains "$path" "require_root"
    assert_file_contains "$path" "[[ \"\${1:-}\" == \"--check\" ]] && exit 0"
    assert_file_contains "$path" "log \"hostname: \$(hostname)\""
    assert_file_contains "$path" "log \"kernel:   \$(uname -r)\""
    assert_file_contains "$path" "for tool in systemd-cryptenroll cryptsetup fwupdmgr; do"
    assert_file_contains "$path" "for tool in tpm2_pcrread ykman fprintd-enroll framework_tool; do"
    assert_file_contains "$path" "if is_framework_laptop; then"
    assert_file_contains "$path" "elif is_vm; then"
    assert_file_contains "$path" "marker_write \"00-sanity\""
}

test_firmware_update_script() {
    local path="$REPO_ROOT/bootstrap/core/05-firmware-update.sh"

    assert_file_contains "$path" "source /usr/share/bootstrap/lib/common.sh"
    assert_file_contains "$path" "require_root"
    assert_file_contains "$path" "[[ \"\${1:-}\" == \"--check\" ]] && CHECK=1"
    assert_file_contains "$path" "if is_vm; then"
    assert_file_contains "$path" "skip \"running in a VM - no real firmware to update\""
    assert_file_contains "$path" "fwupdmgr refresh --force >/dev/null 2>&1 || warn \"fwupd refresh failed (no network?)\""
    assert_file_contains "$path" "PENDING=\$(fwupdmgr get-updates 2>/dev/null"
    assert_file_contains "$path" "if [[ \$PENDING -eq 0 ]]; then"
    assert_file_contains "$path" "if [[ \$CHECK -eq 1 ]]; then"
    assert_file_contains "$path" "fwupdmgr update -y --no-reboot-check || warn \"some updates deferred to next boot\""
    assert_file_contains "$path" "marker_write \"05-firmware\""
}

test_luks_tpm2_script() {
    local path="$REPO_ROOT/bootstrap/core/10-luks-tpm2.sh"

    assert_file_contains "$path" "source /usr/share/bootstrap/lib/common.sh"
    assert_file_contains "$path" "require_root"
    assert_file_contains "$path" "[[ \"\${1:-}\" == \"--check\" ]] && CHECK=1"
    assert_file_contains "$path" "if ! has_encrypted_root; then"
    assert_file_contains "$path" "skip \"root is not LUKS-encrypted - TPM2 enrollment N/A\""
    assert_file_contains "$path" "if ! has_tpm2; then"
    assert_file_contains "$path" "DEV=\$(luks_device)"
    assert_file_contains "$path" "MAPPER=\$(crypt_mapper_name)"
    assert_file_contains "$path" "if has_token \"\$DEV\" \"systemd-tpm2\"; then"
    assert_file_contains "$path" "systemd-cryptenroll \"\$DEV\" --tpm2-device=auto --tpm2-pcrs=7+11"
    assert_file_contains "$path" "grep -qE \"^\${MAPPER}.*tpm2-device=auto\" /etc/crypttab"
    assert_file_contains "$path" "sed -ri \"s|^(\${MAPPER}\\s+\\S+\\s+\\S+)(\\s+.*)?$|\\1 tpm2-device=auto|\" /etc/crypttab"
    assert_file_contains "$path" "mark_boot_artifacts_dirty"
    assert_file_contains "$path" "marker_write \"10-tpm2\""
}

test_luks_fido2_script() {
    local path="$REPO_ROOT/bootstrap/hardware/11-luks-fido2.sh"

    assert_file_contains "$path" "source /usr/share/bootstrap/lib/common.sh"
    assert_file_contains "$path" "require_root"
    assert_file_contains "$path" "[[ \"\${1:-}\" == \"--check\" ]] && CHECK=1"
    assert_file_contains "$path" "if ! has_encrypted_root; then"
    assert_file_contains "$path" "skip \"root is not LUKS-encrypted - FIDO2 enrollment N/A\""
    assert_file_contains "$path" "if ! has_yubikey; then"
    assert_file_contains "$path" "skip \"no YubiKey detected - plug one in and re-run if you want FIDO2\""
    assert_file_contains "$path" "DEV=\$(luks_device)"
    assert_file_contains "$path" "if has_token \"\$DEV\" \"systemd-fido2\"; then"
    assert_file_contains "$path" "systemd-cryptenroll \"\$DEV\" \\"
    assert_file_contains "$path" "--fido2-device=auto \\"
    assert_file_contains "$path" "--fido2-with-client-pin=yes \\"
    assert_file_contains "$path" "--fido2-with-user-presence=yes"
    assert_file_contains "$path" "marker_write \"11-fido2\""
}

test_luks_recovery_script() {
    local path="$REPO_ROOT/bootstrap/core/12-luks-recovery.sh"

    assert_file_contains "$path" "source /usr/share/bootstrap/lib/common.sh"
    assert_file_contains "$path" "require_root"
    assert_file_contains "$path" "[[ \"\${1:-}\" == \"--check\" ]] && CHECK=1"
    assert_file_contains "$path" "if ! has_encrypted_root; then"
    assert_file_contains "$path" "skip \"root is not LUKS-encrypted - recovery key N/A\""
    assert_file_contains "$path" "DEV=\$(luks_device)"
    assert_file_contains "$path" "if has_token \"\$DEV\" \"systemd-recovery\"; then"
    assert_file_contains "$path" "warn \"Recovery key NOT enrolled\""
    assert_file_contains "$path" "systemd-cryptenroll \"\$DEV\" --recovery-key"
    assert_file_contains "$path" "read -rp \"Type 'saved' to confirm you wrote it down: \" ans"
    assert_file_contains "$path" "[[ \"\$ans\" == \"saved\" ]] || err \"not confirmed - re-run to re-display\""
    assert_file_contains "$path" "marker_write \"12-recovery\""
}

test_luks_wipe_installer_script() {
    local path="$REPO_ROOT/bootstrap/core/13-luks-wipe-installer.sh"

    assert_file_contains "$path" "source /usr/share/bootstrap/lib/common.sh"
    assert_file_contains "$path" "require_root"
    assert_file_contains "$path" "[[ \"\${1:-}\" == \"--check\" ]] && CHECK=1"
    assert_file_contains "$path" "if ! has_encrypted_root; then"
    assert_file_contains "$path" "skip \"root is not LUKS-encrypted - nothing to wipe\""
    assert_file_contains "$path" "DUMP=\$(cryptsetup luksDump \"\$DEV\")"
    assert_file_contains "$path" "grep -qE '^\\s*0:\\s+luks2' <<<\"\$DUMP\""
    assert_file_contains "$path" "grep -q \"systemd-tpm2\"     <<<\"\$DUMP\" || err \"Refusing: TPM2 not enrolled\""
    assert_file_contains "$path" "grep -q \"systemd-recovery\" <<<\"\$DUMP\" || err \"Refusing: recovery key not enrolled\""
    assert_file_not_contains "$path" "systemd-fido2"
    assert_file_contains "$path" "cryptsetup luksKillSlot \"\$DEV\" 0"
    assert_file_contains "$path" "mark_boot_artifacts_dirty"
    assert_file_contains "$path" "marker_write \"13-wipe\""
}

test_fingerprint_enroll_script() {
    local path="$REPO_ROOT/bootstrap/hardware/30-fingerprint-enroll.sh"

    assert_file_contains "$path" "source /usr/share/bootstrap/lib/common.sh"
    assert_file_contains "$path" "[[ \"\${1:-}\" == \"--check\" ]] && CHECK=1"
    assert_file_contains "$path" "if ! has_fingerprint_reader; then"
    assert_file_contains "$path" "skip \"no fingerprint reader detected - skipping\""
    assert_file_contains "$path" "USER_NAME=\"\${SUDO_USER:-netf}\""
    assert_file_contains "$path" "sudo -u \"\$USER_NAME\" fprintd-list \"\$USER_NAME\" 2>/dev/null \\"
    assert_file_contains "$path" "grep -q \"right-index-finger\\|left-index-finger\""
    assert_file_contains "$path" "warn \"No fingerprint enrolled\""
    assert_file_contains "$path" "sudo -u \"\$USER_NAME\" fprintd-enroll -f right-index-finger \"\$USER_NAME\""
    assert_file_contains "$path" "marker_write \"30-fprint\""
}

test_framework_ec_script() {
    local path="$REPO_ROOT/bootstrap/hardware/40-framework-ec.sh"

    assert_file_contains "$path" "source /usr/share/bootstrap/lib/common.sh"
    assert_file_contains "$path" "require_root"
    assert_file_contains "$path" "[[ \"\${1:-}\" == \"--check\" ]] && CHECK=1"
    assert_file_contains "$path" "if ! is_framework_laptop; then"
    assert_file_contains "$path" "skip \"not a Framework laptop - skipping EC config\""
    assert_file_contains "$path" "if ! command -v framework_tool >/dev/null 2>&1; then"
    assert_file_contains "$path" "CHARGE_LIMIT=80"
    assert_file_contains "$path" "CURRENT=\$(framework_tool --charge-limit 2>/dev/null \\"
    assert_file_contains "$path" "if [[ \"\$CURRENT\" == \"\$CHARGE_LIMIT\" ]]; then"
    assert_file_contains "$path" "framework_tool --charge-limit \"\$CHARGE_LIMIT\""
    assert_file_contains "$path" "marker_write \"40-ec\""
}

test_run_profile_script() {
    local path="$REPO_ROOT/bootstrap/run-profile.sh"

    assert_file_contains "$path" "source /usr/share/bootstrap/lib/common.sh"
    assert_file_contains "$path" "PROFILE=\"\${1:?profile required}\""
    assert_file_contains "$path" "case \"\$PROFILE\" in"
    assert_file_contains "$path" "core)"
    assert_file_contains "$path" "/usr/share/bootstrap/core"
    assert_file_contains "$path" "hardware)"
    assert_file_contains "$path" "/usr/share/bootstrap/hardware"
    assert_file_contains "$path" "mapfile -t STEPS < <(find \"\$STEP_DIR\" -maxdepth 1 -name '[0-9]*.sh' -type f | sort)"
    assert_file_contains "$path" "BOOT_ARTIFACTS_DIRTY=0"
    assert_file_contains "$path" "if [[ \"\$PROFILE\" == \"core\" ]] && boot_artifacts_dirty; then"
    assert_file_contains "$path" "if [[ \$CHECK -eq 1 ]]; then"
    assert_file_contains "$path" "warn \"core boot artifacts dirty; initramfs rebuild pending\""
    assert_file_contains "$path" "if ! bash \"\$step\" --check; then"
    assert_file_contains "$path" "BOOT_ARTIFACTS_DIRTY=1"
    assert_file_contains "$path" "if [[ \$BOOT_ARTIFACTS_DIRTY -eq 1 ]]; then"
    assert_file_contains "$path" "kver=\$(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d -exec basename {} \\; | sort -V | tail -1)"
    assert_file_contains "$path" "env DRACUT_NO_XATTR=1 dracut -vf \"/usr/lib/modules/\$kver/initramfs.img\" \"\$kver\""
    assert_file_contains "$path" "touch /var/lib/bootstrap/.reboot-required"
    assert_file_contains "$path" "clear_boot_artifacts_dirty"
    assert_file_contains "$path" "warn \"boot artifacts regenerated; reboot required\""
    assert_file_contains "$path" "marker_write \"\$PROFILE\""
}

test_run_profile_check_notices_dirty_boot_artifacts() {
    local tmpdir runner root output status

    tmpdir="$(mktemp -d)"
    root="$tmpdir/bootstrap-root"
    mkdir -p "$root/lib" "$root/core" "$tmpdir/state"

    cat >"$root/lib/common.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
log()  { printf '[bootstrap] %s\n' "\$*" >&2; }
ok()   { printf '[   ok   ] %s\n' "\$*" >&2; }
warn() { printf '[  warn  ] %s\n' "\$*" >&2; }
err()  { printf '[  fail  ] %s\n' "\$*" >&2; exit 2; }
require_root() { :; }
boot_artifacts_dirty() { [[ -f "$tmpdir/state/.boot-artifacts-dirty" ]]; }
clear_boot_artifacts_dirty() { rm -f "$tmpdir/state/.boot-artifacts-dirty"; }
marker_write() { :; }
EOF

    cat >"$root/core/00-noop.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "--check" ]] && exit 0
exit 0
EOF
    chmod +x "$root/core/00-noop.sh"

    runner="$tmpdir/run-profile.sh"
    sed "s|/usr/share/bootstrap|$root|g" "$REPO_ROOT/bootstrap/run-profile.sh" >"$runner"
    chmod +x "$runner"

    touch "$tmpdir/state/.boot-artifacts-dirty"

    set +e
    output="$("$runner" core --check 2>&1)"
    status=$?
    set -e

    [[ $status -ne 0 ]] || fail "expected core --check to fail when boot artifacts are dirty"
    [[ "$output" == *"core boot artifacts dirty; initramfs rebuild pending"* ]] \
        || fail "expected dirty boot artifacts warning during --check"
}

test_run_all_script() {
    local path="$REPO_ROOT/bootstrap/run-all.sh"

    assert_file_contains "$path" "source /usr/share/bootstrap/lib/common.sh"
    assert_file_contains "$path" "require_root"
    assert_file_contains "$path" "[[ \"\${1:-}\" == \"--check\" ]] && CHECK=1"
    assert_file_contains "$path" "for profile in core hardware; do"
    assert_file_contains "$path" "/usr/share/bootstrap/run-profile.sh \"\$profile\""
    assert_file_contains "$path" "/usr/share/bootstrap/run-profile.sh \"\$profile\" --check"
    assert_file_contains "$path" "marker_write \"all\""
    assert_file_contains "$path" "ok \"All bootstrap profiles completed. Reboot recommended.\""
    assert_file_not_contains "$path" "find . -maxdepth 1 -name '[0-9]*.sh'"
}

run_tests() {
    local tests=("$@")
    local test_name

    if [[ ${#tests[@]} -eq 0 ]]; then
        tests=(
            test_netf_bootstrap_service
            test_profile_layout
            test_common_library
            test_sanity_script
            test_firmware_update_script
            test_luks_tpm2_script
            test_luks_fido2_script
            test_luks_recovery_script
            test_luks_wipe_installer_script
            test_fingerprint_enroll_script
            test_framework_ec_script
            test_run_profile_script
            test_run_profile_check_notices_dirty_boot_artifacts
            test_run_all_script
        )
    fi

    for test_name in "${tests[@]}"; do
        declare -F "$test_name" >/dev/null || fail "unknown test: $test_name"
        "$test_name"
    done
}

run_tests "$@"

echo "PASS: bootstrap-scaffold"
