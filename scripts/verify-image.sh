#!/usr/bin/env bash
# Verify a pushed bootc image: cosign signature, expected layers, expected
# binaries. Run from any machine with podman and cosign.
set -euo pipefail

IMAGE_REF=${IMAGE_REF:-ghcr.io/netf/fedora-bootc-starter:44}
PUBKEY=${PUBKEY:-cosign.pub}

if [[ ! -f $PUBKEY ]]; then
    echo "ERROR: $PUBKEY not found. Run from repo root." >&2
    exit 1
fi

echo "Verifying cosign signature for $IMAGE_REF"
cosign verify --key "$PUBKEY" "$IMAGE_REF" > /dev/null
echo "  signature verified"

echo "Pulling image"
podman pull --quiet "$IMAGE_REF" > /dev/null

echo "Running smoke test inside image"
podman run --rm "$IMAGE_REF" bash -c '
    set -e
    test -x /usr/share/bootstrap/run-all.sh
    test -f /usr/lib/bootc/kargs.d/10-fw13.toml
    test -f /etc/containers/policy.json
    test -f /etc/containers/pubkey.pem
    command -v chezmoi mise alacritty distrobox tailscale framework_tool >/dev/null
    echo "  image content OK"
'
echo "$IMAGE_REF verified"
