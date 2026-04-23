#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_PATH="$REPO_ROOT/config.toml.in"

: "${INSTALL_LUKS_PASSPHRASE:?INSTALL_LUKS_PASSPHRASE is required}"
: "${ADMIN_PASSWORD_HASH:?ADMIN_PASSWORD_HASH is required}"
: "${EXTRA_USER_BLOCKS?EXTRA_USER_BLOCKS must be set}"
: "${EXTRA_KERNEL_APPEND?EXTRA_KERNEL_APPEND must be set}"

[[ -f "$TEMPLATE_PATH" ]] || {
    echo "ERROR: missing template: $TEMPLATE_PATH" >&2
    exit 1
}

TEMPLATE_PATH="$TEMPLATE_PATH" python3 - <<'PY'
import json
import os
import pathlib
import sys

template_path = pathlib.Path(os.environ["TEMPLATE_PATH"])
rendered = template_path.read_text()


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def validate_passphrase(value: str) -> str:
    if not value:
        fail("INSTALL_LUKS_PASSPHRASE must not be empty")
    if any(ch.isspace() for ch in value) or any(ord(ch) < 0x20 for ch in value):
        fail("unsafe INSTALL_LUKS_PASSPHRASE: must not contain whitespace or control characters")
    return value


def escape_toml_basic_string(value: str) -> str:
    if "\x00" in value:
        fail("EXTRA_KERNEL_APPEND must not contain NUL bytes")
    return json.dumps(value)[1:-1]

replacements = {
    "{{INSTALL_LUKS_PASSPHRASE}}": validate_passphrase(os.environ["INSTALL_LUKS_PASSPHRASE"]),
    "{{ADMIN_PASSWORD_HASH}}": os.environ["ADMIN_PASSWORD_HASH"],
    "{{EXTRA_USER_BLOCKS}}": os.environ["EXTRA_USER_BLOCKS"],
    "{{EXTRA_KERNEL_APPEND}}": escape_toml_basic_string(os.environ["EXTRA_KERNEL_APPEND"]),
}

for needle, replacement in replacements.items():
    rendered = rendered.replace(needle, replacement)

if "{{" in rendered or "}}" in rendered:
    raise SystemExit("ERROR: unresolved template placeholders remain")

sys.stdout.write(rendered)
PY
