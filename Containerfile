# syntax=docker/dockerfile:1

ARG FEDORA_VERSION=44

# ---- Stage 1: build framework_tool from source ---------------------------
FROM quay.io/fedora/fedora:${FEDORA_VERSION} AS fw-tool-builder
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG FW_TOOL_VERSION=v0.4.0
# hadolint ignore=DL3041
RUN dnf install -y rust cargo systemd-devel hidapi-devel git pkgconf-pkg-config \
 && git clone --depth 1 --branch ${FW_TOOL_VERSION} \
      https://github.com/FrameworkComputer/framework-system /src \
 && dnf clean all
WORKDIR /src
RUN cargo build --release -p framework_tool \
 && dnf clean all

# ---- Stage 2: the actual bootc image -------------------------------------
FROM quay.io/fedora-ostree-desktops/kinoite:${FEDORA_VERSION}
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# ---- Layered packages ----------------------------------------------------
# Strict policy: only things that must be root-installed, kernel-matched, or
# needed before dotfiles bootstrap can even run. Modern CLI lives in dotfiles.
RUN rpm-ostree install \
      git-core \
      chezmoi \
      alacritty \
      podman-compose distrobox \
      tailscale wireguard-tools \
      tpm2-tools yubikey-manager fido2-tools \
      fprintd fprintd-pam \
      sbsigntools \
      iio-sensor-proxy \
      fwupd \
      kdeconnectd \
      jetbrains-mono-fonts-all fira-code-fonts \
      bpftool bpftrace kernel-tools \
      restic \
 && ostree container commit

# framework_tool from stage 1
COPY --from=fw-tool-builder /src/target/release/framework_tool /usr/local/bin/framework_tool
# System config: /usr/etc/* is copied to /etc/ on deploy with 3-way merge.
# systemd unit: /usr/lib/systemd/system/* is package-owned (correct location).
COPY files/usr/ /usr/

# Bootstrap scripts
COPY bootstrap/ /usr/share/bootstrap/

# Embed cosign public key for signature enforcement
COPY cosign.pub /usr/etc/containers/pubkey.pem

# Build-time setup and validation:
# - install mise
# - wire bootstrap scripts and signature policy
# - regenerate initramfs with TPM2/FIDO2 modules
# - write kernel args
# - enable first-boot unit
# - lint the final bootc image
RUN chmod +x /usr/local/bin/framework_tool \
 && curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh \
 && ostree container commit \
 && chmod +x /usr/share/bootstrap/*.sh /usr/share/bootstrap/lib/*.sh \
 && grep -q "/usr/etc/containers/pubkey.pem" /usr/etc/containers/policy.json \
 && test -f /usr/etc/containers/pubkey.pem \
 && echo "signature policy wired correctly" \
 && printf 'add_dracutmodules+=" crypt tpm2-tss systemd-cryptsetup fido2 systemd "\n' \
      > /usr/lib/dracut/dracut.conf.d/50-luks-unlock.conf \
 && kver=$(rpm -q kernel --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort -V | tail -1) \
 && test -n "$kver" \
 && env DRACUT_NO_XATTR=1 dracut -vf "/usr/lib/modules/$kver/initramfs.img" "$kver" \
 && mkdir -p /usr/lib/bootc/kargs.d \
 && printf 'kargs = [\n  "intel_iommu=on",\n  "rd.luks.options=discard",\n  "mem_sleep_default=s2idle",\n  "quiet",\n  "splash",\n]\n' \
      > /usr/lib/bootc/kargs.d/10-fw13.toml \
 && systemctl enable netf-bootstrap.service \
 && bootc container lint
