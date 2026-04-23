#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_file_matches() {
    local path="$1"
    local expected="$2"

    [[ -f "$path" ]] || fail "missing file: $path"

    local actual
    actual="$(<"$path")"
    [[ "$actual" == "$expected" ]] || fail "unexpected contents in $path"
}

assert_file_contains() {
    local path="$1"
    local needle="$2"

    [[ -f "$path" ]] || fail "missing file: $path"

    local actual
    actual="$(<"$path")"
    [[ "$actual" == *"$needle"* ]] || fail "expected $path to contain: $needle"
}

test_netf_bootstrap_service() {
    local expected
    expected="$(cat <<'EOF'
[Unit]
Description=Piotr first-boot bootstrap (LUKS enrollment, firmware, EC tuning)
After=systemd-user-sessions.service network-online.target
Wants=network-online.target
ConditionPathExists=!/var/lib/bootstrap/.all.done

[Service]
Type=oneshot
ExecStart=/usr/share/bootstrap/run-all.sh --interactive
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF
)"

    assert_file_matches "$REPO_ROOT/files/usr/lib/systemd/system/netf-bootstrap.service" "$expected"
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
    assert_file_contains "$path" "marker_done()  { [[ -f \"/var/lib/bootstrap/.\${1}.done\" ]]; }"
    assert_file_contains "$path" "marker_write() { mkdir -p /var/lib/bootstrap && touch \"/var/lib/bootstrap/.\${1}.done\"; }"
}

test_sanity_script() {
    local path="$REPO_ROOT/bootstrap/00-sanity.sh"

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
    local path="$REPO_ROOT/bootstrap/05-firmware-update.sh"

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
    local path="$REPO_ROOT/bootstrap/10-luks-tpm2.sh"

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
    assert_file_contains "$path" "marker_write \"10-tpm2\""
}

test_luks_fido2_script() {
    local path="$REPO_ROOT/bootstrap/11-luks-fido2.sh"

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
    local path="$REPO_ROOT/bootstrap/12-luks-recovery.sh"

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
    local path="$REPO_ROOT/bootstrap/13-luks-wipe-installer.sh"

    assert_file_contains "$path" "source /usr/share/bootstrap/lib/common.sh"
    assert_file_contains "$path" "require_root"
    assert_file_contains "$path" "[[ \"\${1:-}\" == \"--check\" ]] && CHECK=1"
    assert_file_contains "$path" "if ! has_encrypted_root; then"
    assert_file_contains "$path" "skip \"root is not LUKS-encrypted - nothing to wipe\""
    assert_file_contains "$path" "DUMP=\$(cryptsetup luksDump \"\$DEV\")"
    assert_file_contains "$path" "grep -qE '^\\s*0:\\s+luks2' <<<\"\$DUMP\""
    assert_file_contains "$path" "grep -q \"systemd-tpm2\"     <<<\"\$DUMP\" || err \"Refusing: TPM2 not enrolled\""
    assert_file_contains "$path" "grep -q \"systemd-fido2\"    <<<\"\$DUMP\" || err \"Refusing: FIDO2 not enrolled\""
    assert_file_contains "$path" "grep -q \"systemd-recovery\" <<<\"\$DUMP\" || err \"Refusing: recovery key not enrolled\""
    assert_file_contains "$path" "cryptsetup luksKillSlot \"\$DEV\" 0"
    assert_file_contains "$path" "marker_write \"13-wipe\""
}

test_fingerprint_enroll_script() {
    local path="$REPO_ROOT/bootstrap/30-fingerprint-enroll.sh"

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

run_tests() {
    local tests=("$@")
    local test_name

    if [[ ${#tests[@]} -eq 0 ]]; then
        tests=(
            test_netf_bootstrap_service
            test_common_library
            test_sanity_script
            test_firmware_update_script
            test_luks_tpm2_script
            test_luks_fido2_script
            test_luks_recovery_script
            test_luks_wipe_installer_script
            test_fingerprint_enroll_script
        )
    fi

    for test_name in "${tests[@]}"; do
        declare -F "$test_name" >/dev/null || fail "unknown test: $test_name"
        "$test_name"
    done
}

run_tests "$@"

echo "PASS: bootstrap-scaffold"
