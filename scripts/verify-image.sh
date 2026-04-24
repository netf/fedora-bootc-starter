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
    test -x /usr/share/bootstrap/run-profile.sh
    test -x /usr/share/bootstrap/core/10-luks-tpm2.sh
    test -x /usr/share/bootstrap/hardware/11-luks-fido2.sh
    grep -q "^ExecStart=/usr/share/bootstrap/run-profile.sh core$" /usr/lib/systemd/system/netf-bootstrap.service
    systemctl is-enabled netf-bootstrap.service >/dev/null
    test -f /usr/lib/bootc/kargs.d/10-fw13.toml
    test -f /etc/containers/policy.json
    test -f /etc/containers/pubkey.pem
    command -v chezmoi mise alacritty distrobox tailscale framework_tool >/dev/null
    echo "  image content OK"
'
echo "$IMAGE_REF verified"
