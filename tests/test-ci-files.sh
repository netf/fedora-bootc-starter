#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_file_contains() {
    local path="$1"
    local needle="$2"

    [[ -f "$path" ]] || fail "missing file: $path"

    local actual
    actual="$(<"$path")"
    [[ "$actual" == *"$needle"* ]] || fail "expected $path to contain: $needle"
}

assert_file_not_contains() {
    local path="$1"
    local needle="$2"

    [[ -f "$path" ]] || fail "missing file: $path"

    local actual
    actual="$(<"$path")"
    [[ "$actual" != *"$needle"* ]] || fail "expected $path to not contain: $needle"
}

test_build_workflow() {
    local path="$REPO_ROOT/.github/workflows/build.yml"

    [[ -f "$path" ]] || fail "missing file: $path"
    assert_file_contains "$path" "name: build"
    assert_file_contains "$path" "workflow_dispatch:"
    assert_file_contains "$path" "job_mode:"
    assert_file_contains "$path" "default: full"
    assert_file_contains "$path" "- e2e-only"
    assert_file_contains "$path" "FEDORA_VERSION: \${{ inputs.fedora_version || '44' }}"
    assert_file_contains "$path" "lint:"
    assert_file_contains "$path" "build:"
    assert_file_contains "$path" "e2e-vm:"
    assert_file_contains "$path" "if: \${{ github.event_name != 'workflow_dispatch' || github.event.inputs.job_mode != 'e2e-only' }}"
    assert_file_contains "$path" "needs: lint"
    assert_file_contains "$path" "uses: hadolint/hadolint-action@v3.3.0"
    assert_file_contains "$path" "uses: sigstore/cosign-installer@v3"
    assert_file_contains "$path" "config-ci-rendered.toml"
    assert_file_contains "$path" "Render encrypted installer config"
    assert_file_contains "$path" "Generate CI installer passphrase"
    assert_file_contains "$path" "INSTALL_LUKS_PASSPHRASE"
    assert_file_contains "$path" "EXTRA_USER_BLOCKS"
    assert_file_contains "$path" "[[customizations.user]]"
    assert_file_contains "$path" "RENDERED_CONFIG=\"\$(mktemp)\""
    assert_file_contains "$path" "./scripts/render-installer-config.sh > \"\$RENDERED_CONFIG\""
    assert_file_contains "$path" "./scripts/render-installer-config.sh > config-ci-rendered.toml"
    assert_file_contains "$path" "uses: actions/upload-artifact@v4"
    assert_file_contains "$path" "podman login --compat-auth-file \"\$HOME/.docker/config.json\""
    assert_file_contains "$path" "--progress verbose"
    assert_file_contains "$path" "--type qcow2 --rootfs btrfs --config /config.toml"
    assert_file_contains "$path" "lsinitrd /usr/lib/modules/\$KVER/initramfs.img | grep -q ostree"
    assert_file_contains "$path" "systemctl is-enabled sshd.service"
    assert_file_contains "$path" "ls -l /usr/share/OVMF"
    assert_file_contains "$path" "/usr/share/OVMF/OVMF_CODE_4M.fd"
    assert_file_contains "$path" "/usr/share/OVMF/OVMF_VARS_4M.fd"
    assert_file_contains "$path" "echo \"OVMF_CODE=\$OVMF_CODE\" >> \"\$GITHUB_ENV\""
    assert_file_contains "$path" "echo \"OVMF_VARS_TEMPLATE=\$OVMF_VARS_TEMPLATE\" >> \"\$GITHUB_ENV\""
    assert_file_contains "$path" "cp \"\$OVMF_VARS_TEMPLATE\" ovmf-vars.fd"
    assert_file_contains "$path" "mkfifo vm-serial.in vm-serial.out"
    assert_file_contains "$path" "file=\$OVMF_CODE"
    assert_file_contains "$path" "file=ovmf-vars.fd"
    assert_file_contains "$path" "-serial pipe:vm-serial"
    assert_file_contains "$path" "> qemu-launch.log 2>&1 &"
    assert_file_contains "$path" "grep -qi 'Passphrase'"
    assert_file_contains "$path" "printf '%s\\n' \"\$INSTALL_LUKS_PASSPHRASE\" > vm-serial.in"
    assert_file_contains "$path" "sent LUKS passphrase over serial"
    assert_file_contains "$path" "kill -0 \"\$(cat qemu.pid)\""
    assert_file_contains "$path" "VM serial log excerpt"
    assert_file_contains "$path" "tail -n 40 vm-serial.log || true"
    assert_file_contains "$path" "tail -n 200 qemu-launch.log"
    assert_file_contains "$path" "tail -n 200 vm-serial.log"
    assert_file_contains "$path" "ROOT_SSH=\"ssh -i ci-key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2222 root@localhost\""
    assert_file_contains "$path" "\$ROOT_SSH 'bootc status'"
    assert_file_contains "$path" "\$ROOT_SSH 'tpm2_pcrread sha256:7,11'"
    assert_file_contains "$path" "root@localhost 'systemctl poweroff' || true"
    assert_file_contains "$path" "command -v chezmoi mise alacritty distrobox tailscale tpm2_pcrread"
    assert_file_contains "$path" "fprintd-enroll sshd"
    assert_file_contains "$path" "sbverify"
    assert_file_not_contains "$path" "sbctl"
    assert_file_not_contains "$path" "netf@localhost 'sudo systemctl poweroff' || true"
    assert_file_not_contains "$path" "tomllib.load(open('config.toml','rb'))"
    assert_file_not_contains "$path" "config-ci.toml"
    assert_file_contains "$path" "files/etc/containers/registries.d/"
    assert_file_contains "$path" "/etc/containers/policy.json"
    assert_file_not_contains "$path" "/usr/etc"
}

run_tests() {
    local tests=("$@")
    local test_name

    if [[ ${#tests[@]} -eq 0 ]]; then
        tests=(test_build_workflow)
    fi

    for test_name in "${tests[@]}"; do
        declare -F "$test_name" >/dev/null || fail "unknown test: $test_name"
        "$test_name"
    done
}

run_tests "$@"

echo "PASS: ci-files"
