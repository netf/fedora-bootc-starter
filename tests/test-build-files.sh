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

test_containerfile() {
    local path="$REPO_ROOT/Containerfile"

    [[ -f "$path" ]] || fail "missing file: $path"
    assert_file_contains "$path" "# syntax=docker/dockerfile:1"
    assert_file_contains "$path" "ARG FEDORA_VERSION=44"
    assert_file_contains "$path" "FROM quay.io/fedora/fedora:\${FEDORA_VERSION} AS fw-tool-builder"
    assert_file_contains "$path" "ARG FW_TOOL_VERSION=v0.4.0"
    assert_file_contains "$path" "FROM quay.io/fedora-ostree-desktops/kinoite:\${FEDORA_VERSION}"
    assert_file_contains "$path" "COPY bootstrap/ /usr/share/bootstrap/"
    assert_file_contains "$path" "COPY cosign.pub /usr/etc/containers/pubkey.pem"
    assert_file_contains "$path" "sbsigntools"
    assert_file_not_contains "$path" "sbctl"
    assert_file_contains "$path" "dracut.conf.d/50-luks-unlock.conf"
    assert_file_contains "$path" "/usr/lib/bootc/kargs.d/10-fw13.toml"
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
    assert_file_contains "$path" "test-vm: iso  ## Boot the ISO in QEMU with swtpm for end-to-end testing"
}

run_tests() {
    local tests=("$@")
    local test_name

    if [[ ${#tests[@]} -eq 0 ]]; then
        tests=(test_containerfile test_makefile)
    fi

    for test_name in "${tests[@]}"; do
        declare -F "$test_name" >/dev/null || fail "unknown test: $test_name"
        "$test_name"
    done
}

run_tests "$@"

echo "PASS: build-files"
