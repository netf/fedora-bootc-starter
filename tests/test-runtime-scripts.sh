#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

test_test_vm_script() {
    local path="$REPO_ROOT/scripts/test-vm.sh"

    [[ -f "$path" ]] || fail "missing file: $path"
    assert_file_contains "$path" "ISO=\${ISO:-output/bootiso/install.iso}"
    assert_file_contains "$path" "DISK=\${DISK:-output/test-disk.qcow2}"
    assert_file_contains "$path" "TPM_DIR=\$(mktemp -d)"
    assert_file_contains "$path" "qemu-img create -f qcow2 \"\$DISK\" 60G"
    assert_file_contains "$path" "swtpm socket --tpm2 --tpmstate dir=\"\$TPM_DIR\""
    assert_file_contains "$path" "qemu-system-x86_64 \\"
    assert_file_contains "$path" "-tpmdev emulator,id=tpm0,chardev=chrtpm"
    assert_file_contains "$path" "-display gtk"
}

test_verify_image_script() {
    local path="$REPO_ROOT/scripts/verify-image.sh"

    [[ -f "$path" ]] || fail "missing file: $path"
    assert_file_contains "$path" "IMAGE_REF=\${IMAGE_REF:-ghcr.io/netf/fedora-bootc-starter:44}"
    assert_file_contains "$path" "PUBKEY=\${PUBKEY:-cosign.pub}"
    assert_file_contains "$path" "cosign verify --key \"\$PUBKEY\" \"\$IMAGE_REF\" > /dev/null"
    assert_file_contains "$path" "podman pull --quiet \"\$IMAGE_REF\" > /dev/null"
    assert_file_contains "$path" "podman run --rm \"\$IMAGE_REF\" bash -c '"
    assert_file_contains "$path" "test -x /usr/share/bootstrap/run-profile.sh"
    assert_file_contains "$path" "test -x /usr/share/bootstrap/core/10-luks-tpm2.sh"
    assert_file_contains "$path" "test -x /usr/share/bootstrap/hardware/11-luks-fido2.sh"
    assert_file_contains "$path" 'grep -q "^ExecStart=/usr/share/bootstrap/run-profile.sh core$" /usr/lib/systemd/system/netf-bootstrap.service'
    assert_file_contains "$path" "systemctl is-enabled netf-bootstrap.service >/dev/null"
    assert_file_contains "$path" "test -f /etc/containers/pubkey.pem"
    assert_file_contains "$path" "command -v chezmoi mise alacritty distrobox tailscale framework_tool >/dev/null"
}

run_tests() {
    local tests=("$@")
    local test_name

    if [[ ${#tests[@]} -eq 0 ]]; then
        tests=(test_test_vm_script test_verify_image_script)
    fi

    for test_name in "${tests[@]}"; do
        declare -F "$test_name" >/dev/null || fail "unknown test: $test_name"
        "$test_name"
    done
}

run_tests "$@"

echo "PASS: runtime-scripts"
