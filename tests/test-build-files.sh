#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

extract_makefile_default_admin_hash() {
    local path="$REPO_ROOT/Makefile"
    local value

    [[ -f "$path" ]] || fail "missing file: $path"

    value="$(sed -n 's/^export ADMIN_PASSWORD_HASH ?= //p' "$path")"
    [[ -n "$value" ]] || fail "failed to extract ADMIN_PASSWORD_HASH default from $path"

    value="${value//\$\$/\$}"
    printf '%s' "$value"
}

test_containerfile() {
    local path="$REPO_ROOT/Containerfile"

    [[ -f "$path" ]] || fail "missing file: $path"
    assert_file_contains "$path" "# syntax=docker/dockerfile:1"
    assert_file_contains "$path" "ARG FEDORA_VERSION=44"
    assert_file_contains "$path" "FROM quay.io/fedora/fedora:\${FEDORA_VERSION} AS fw-tool-builder"
    assert_file_contains "$path" "ARG FW_TOOL_VERSION=v0.4.0"
    assert_file_contains "$path" "FROM quay.io/fedora-ostree-desktops/kinoite:\${FEDORA_VERSION}"
    assert_file_contains "$path" "COPY files/ /"
    assert_file_contains "$path" "COPY bootstrap/ /usr/share/bootstrap/"
    assert_file_contains "$path" "COPY cosign.pub /etc/containers/pubkey.pem"
    assert_file_contains "$path" "openssh-server"
    assert_file_contains "$path" "sbsigntools"
    assert_file_not_contains "$path" "sbctl"
    assert_file_not_contains "$path" "/usr/etc"
    assert_file_contains "$path" "chmod +x /usr/share/bootstrap/*.sh /usr/share/bootstrap/core/*.sh /usr/share/bootstrap/hardware/*.sh /usr/share/bootstrap/lib/*.sh"
    assert_file_contains "$path" "test -x /usr/share/bootstrap/run-profile.sh"
    assert_file_contains "$path" "test -x /usr/share/bootstrap/core/10-luks-tpm2.sh"
    assert_file_contains "$path" "test -x /usr/share/bootstrap/hardware/11-luks-fido2.sh"
    assert_file_contains "$path" "grep -q '^ExecStart=/usr/share/bootstrap/run-profile.sh core$' /usr/lib/systemd/system/netf-bootstrap.service"
    assert_file_contains "$path" "dracut.conf.d/50-luks-unlock.conf"
    assert_file_contains "$path" "add_dracutmodules+=\" crypt tpm2-tss systemd-cryptsetup fido2 systemd ostree \""
    assert_file_contains "$path" "/usr/lib/bootc/kargs.d/10-fw13.toml"
    assert_file_contains "$path" "systemctl enable sshd.service"
    assert_file_contains "$path" "systemctl enable netf-bootstrap.service"
    assert_file_contains "$path" "bootc container lint"
}

test_makefile() {
    local path="$REPO_ROOT/Makefile"

    [[ -f "$path" ]] || fail "missing file: $path"
    assert_file_contains "$path" "FEDORA_VERSION ?= 44"
    assert_file_contains "$path" "FW_TOOL_VERSION ?= v0.4.0"
    assert_file_contains "$path" "IMAGE_REF      ?= ghcr.io/netf/fedora-bootc-starter:\$(FEDORA_VERSION)"
    assert_file_contains "$path" "lint:  ## Lint Containerfile, shell scripts, and YAML"
    assert_file_contains "$path" "build:  ## Build the bootc image locally (requires Linux host)"
    assert_file_contains "$path" "sign:  ## cosign sign the pushed image DIGEST (not tag)"
    assert_file_contains "$path" "iso: build  ## Build the unattended installer ISO"
    assert_file_contains "$path" "export INSTALL_LUKS_PASSPHRASE ?="
    assert_file_contains "$path" "export ADMIN_PASSWORD_HASH ?="
    assert_file_contains "$path" "test -x /usr/share/bootstrap/run-profile.sh;"
    assert_file_contains "$path" "test -x /usr/share/bootstrap/core/10-luks-tpm2.sh;"
    assert_file_contains "$path" "test -x /usr/share/bootstrap/hardware/11-luks-fido2.sh;"
    assert_file_contains "$path" 'grep -q "^ExecStart=/usr/share/bootstrap/run-profile.sh core$$" /usr/lib/systemd/system/netf-bootstrap.service;'
    assert_file_contains "$path" "systemctl is-enabled netf-bootstrap.service;"
    assert_file_contains "$path" "--type anaconda-iso --rootfs btrfs"
    assert_file_contains "$path" "test-vm: iso  ## Boot the ISO in QEMU with swtpm for end-to-end testing"
}

test_makefile_renders_installer_config() {
    local path="$REPO_ROOT/Makefile"

    [[ -f "$path" ]] || fail "missing file: $path"
    assert_file_contains "$path" 'ERROR: INSTALL_LUKS_PASSPHRASE is required'
    assert_file_contains "$path" "@test -n \"\$\$INSTALL_LUKS_PASSPHRASE\""
    assert_file_contains "$path" "./scripts/render-installer-config.sh > \"\$\$RENDERED_CONFIG\""
    assert_file_contains "$path" "RENDERED_CONFIG=\$\$(mktemp"
    assert_file_contains "$path" "-v \"\$\$RENDERED_CONFIG\":/config.toml:ro"
    assert_file_not_contains "$path" "-v \$(PWD)/config.toml:/config.toml:ro"
}

test_make_iso_operator_interface() {
    local stub_dir
    local output_dir
    local log_dir
    local config_capture
    local default_hash
    local output

    stub_dir="$(mktemp -d)"
    output_dir=".test-output-make-iso"
    log_dir="$(mktemp -d)"
    config_capture="$log_dir/rendered-config.toml"
    default_hash="$(extract_makefile_default_admin_hash)"

    cat >"$stub_dir/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
    chmod +x "$stub_dir/sudo"

    cat >"$stub_dir/podman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log_dir="${TEST_LOG_DIR:?}"
mkdir -p "$log_dir"

printf '%s\n' "$*" >>"$log_dir/podman.log"

if [[ "${1:-}" == "build" ]]; then
    exit 0
fi

if [[ "${1:-}" == "run" ]]; then
    config_mount=""
    output_mount=""

    shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -v)
                case "$2" in
                    *:/config.toml:ro) config_mount="${2%%:/config.toml:ro}" ;;
                    *:/output) output_mount="${2%%:/output}" ;;
                esac
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    [[ -n "$config_mount" ]] || exit 1
    cp "$config_mount" "$log_dir/rendered-config.toml"

    if [[ -n "$output_mount" ]]; then
        mkdir -p "$output_mount/bootiso"
        : >"$output_mount/bootiso/install.iso"
    fi

    exit 0
fi

exit 1
EOF
    chmod +x "$stub_dir/podman"

    assert_command_fails_contains "ERROR: INSTALL_LUKS_PASSPHRASE is required" \
        env \
        PATH="$stub_dir:$PATH" \
        TEST_LOG_DIR="$log_dir" \
        make \
        OUTPUT_DIR="$output_dir" \
        iso

    output="$(
        env \
            PATH="$stub_dir:$PATH" \
            TEST_LOG_DIR="$log_dir" \
            INSTALL_LUKS_PASSPHRASE="rendered-passphrase" \
            make \
            OUTPUT_DIR="$output_dir" \
            iso
    )" || fail "expected make iso to succeed with only INSTALL_LUKS_PASSPHRASE set"

    [[ -f "$config_capture" ]] || fail "expected fake podman to capture rendered config"
    assert_file_contains "$config_capture" "user --name=netf --groups=wheel --iscrypted --password='$default_hash'"
    [[ "$output" == *"ISO ready: $output_dir/bootiso/install.iso"* ]] || fail "expected make iso success output"

    output="$(
        env \
            PATH="$stub_dir:$PATH" \
            TEST_LOG_DIR="$log_dir" \
            INSTALL_LUKS_PASSPHRASE="rendered-passphrase" \
            ADMIN_PASSWORD_HASH="\$6\$override\$hash-value" \
            EXTRA_SSHKEY_LINES="" \
            EXTRA_KERNEL_APPEND="" \
            make \
            OUTPUT_DIR="$output_dir" \
            iso
    )" || fail "expected make iso to succeed with stubbed podman"

    [[ -f "$config_capture" ]] || fail "expected fake podman to capture rendered config"
    assert_file_contains "$config_capture" "user --name=netf --groups=wheel --iscrypted --password='\$6\$override\$hash-value'"
    [[ "$output" == *"ISO ready: $output_dir/bootiso/install.iso"* ]] || fail "expected make iso success output"

    rm -rf "$stub_dir" "$log_dir" "${REPO_ROOT:?}/$output_dir"
}

run_tests() {
    local tests=("$@")
    local test_name

    if [[ ${#tests[@]} -eq 0 ]]; then
        tests=(test_containerfile test_makefile test_makefile_renders_installer_config test_make_iso_operator_interface)
    fi

    for test_name in "${tests[@]}"; do
        declare -F "$test_name" >/dev/null || fail "unknown test: $test_name"
        "$test_name"
    done
}

run_tests "$@"

echo "PASS: build-files"
