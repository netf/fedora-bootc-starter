# fedora-bootc-starter — design spec

**Date:** 2026-04-23
**Repo:** github.com/netf/fedora-bootc-starter
**Image:** `ghcr.io/netf/fedora-bootc-starter:${FEDORA_VERSION}` (default `44`)
**Hardware target:** Framework Laptop 13 Pro (Intel Core Ultra Series 3 / Panther Lake)

## 1. Purpose

Build a personal, well-tested "Universal Blue-like" Fedora Kinoite bootc image for a Framework 13 Pro. The container image is the source of truth for the host OS; a kickstart-backed installer ISO handles partitioning + LUKS2; first-boot scripts enroll TPM2/FIDO2/YubiKey as additional LUKS keyslots, apply LVFS firmware, and configure the Framework embedded controller.

Source of truth for architectural intent: `guide.md` at repo root. This spec supersedes `guide.md` where they disagree, and captures corrections identified during the 2026-04-23 brainstorming pass.

## 2. Goals

- One signed bootc image, tagged by Fedora version, pullable from GHCR.
- Unattended installer ISO — single USB, no network during install.
- Idempotent first-boot bootstrap; every script supports `--check` dry-run.
- **CI must be green on every push to main** — build, signature, and VM-level e2e all automated. CI is the canonical build path.
- Hardware-specific paths (YubiKey, Goodix, Framework EC) **skip cleanly** on non-matching hardware so the image is usable in a VM and testable in GitHub Actions.
- Clean boundary with [netf/dotfiles](https://github.com/netf/dotfiles): image = minimal host foundation for dotfiles bootstrap + system-level services. Dotfiles = everything else (flatpaks, modern CLI, dev languages, toolbox).

## 3. Non-goals (v1)

Out of scope, explicitly:

- Flatpak installation — owned by dotfiles.
- Dev toolchains / language runtimes (Node, Python, Go, Rust, kubectl, terraform, etc.) — owned by dotfiles via `mise`.
- Toolbox container contents (zsh, tmux, neovim, dev CLIs) — owned by dotfiles.
- GUI desktop theming / keybindings — owned by dotfiles.
- Rechunking (hhd-dev/rechunk), multi-stream variants (stable/beta), akmods, Renovate digest pinning. Revisit if the image grows past a single-laptop deployment.

## 4. Parameterization

Single variable `FEDORA_VERSION` flows through:

- `Containerfile`: `ARG FEDORA_VERSION=44`, used for both builder and final FROM.
- `Makefile`: `FEDORA_VERSION ?= 44`, `IMAGE_REF ?= ghcr.io/netf/fedora-bootc-starter:$(FEDORA_VERSION)`.
- `.github/workflows/build.yml`: `workflow_dispatch` input `fedora_version` (default `44`), consumed as `--build-arg FEDORA_VERSION=...`.

Swapping to F45 for a major upgrade = change one default in three places. No other tree changes required.

## 5. Architecture

Four execution phases, strict separation of responsibility:

| Phase | Where | What |
|---|---|---|
| **Build-time** | `podman build` (local or CI) | package install, `framework_tool` compile, initramfs regen with TPM2/FIDO2 modules, kargs, bootstrap scripts embedded at `/usr/share/bootstrap/`, cosign public key at `/usr/etc/containers/pubkey.pem`, `bootc container lint` |
| **Install-time** | `bootc-image-builder --type anaconda-iso` + kickstart | partitioning (btrfs on LUKS2/argon2id), throwaway installer passphrase, unattended user (`netf`, wheel), services enabled |
| **First-boot** | `netf-bootstrap.service` (systemd oneshot) → `bootstrap/run-all.sh` | firmware → TPM2 → FIDO2 → recovery key → wipe installer pw → fingerprint → EC config. Each step idempotent; hardware gates skip cleanly. |
| **User-time** | out of scope; motd prints handoff | `chezmoi init --apply netf`, dotfiles applies everything else |

## 6. Image contents

### 6.1 Packages (rpm-ostree install)

**Host foundation for dotfiles bootstrap:**
- `git-core`, `chezmoi`, `alacritty`
- `podman-compose`, `distrobox` (toolbox runtime)

**`mise`** installed separately via `curl https://mise.run` → `/usr/local/bin/mise`.
**`starship`** is NOT in the image (owned by dotfiles).

**Networking / mesh (system services):**
- `tailscale`, `wireguard-tools`

**LUKS / auth hardware (used by first-boot as root):**
- `tpm2-tools`, `yubikey-manager`, `fido2-tools`
- `fprintd`, `fprintd-pam`
- `sbsigntools` (`sbverify`, `sbsign`)

**Framework hardware:**
- `iio-sensor-proxy`, `fwupd`
- `framework_tool` — built from source in a builder stage (pinned to `FW_TOOL_VERSION`, default `v0.4.0`).

**KDE integration not in Kinoite base:**
- `kdeconnectd`

**Fonts (system-wide, terminals need them pre-login):**
- `jetbrains-mono-fonts-all`, `fira-code-fonts`

**Kernel-matched (version-locked to image kernel):**
- `bpftool`, `bpftrace`, `kernel-tools`

**System backup:**
- `restic`

### 6.2 Explicitly NOT in the image (boundary with dotfiles)

`eza`, `bat`, `ripgrep`, `fd-find`, `jq`, `yq`, `gh`, `just`, `fzf`, `delta`, `zoxide`, `age`, `sops`, `kubectl`, `helm`, `k9s`, `kind`, `k3d`, `terraform`, `terragrunt`, AWS/Azure CLI, dnscrypt-proxy, all language runtimes. Negative assertions in CI smoke test enforce this.

### 6.3 Kernel args

`/usr/lib/bootc/kargs.d/10-fw13.toml`:
```toml
kargs = [
  "intel_iommu=on",
  "rd.luks.options=discard",
  "mem_sleep_default=s2idle",
  "quiet",
  "splash",
]
```

### 6.4 Initramfs

Dracut config at `/usr/lib/dracut/dracut.conf.d/50-luks-unlock.conf`:
```
add_dracutmodules+=" crypt tpm2-tss systemd-cryptsetup fido2 systemd ostree "
```

Regenerated at build-time (runtime regen is impossible on bootc because `/usr` is read-only):

```dockerfile
kver=$(rpm -q kernel --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort -V | tail -1)
env DRACUT_NO_XATTR=1 dracut -vf /usr/lib/modules/$kver/initramfs.img "$kver"
```

Note the kernel-version detection is via `rpm -q`, not `ls /usr/lib/modules | head -1` — more robust across kernel packaging edge cases.

### 6.5 First-boot systemd unit

`/usr/lib/systemd/system/netf-bootstrap.service` (package-provided unit path, not `/etc/`):
```ini
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
```

Enabled at build time with `systemctl enable netf-bootstrap.service` (creates the `multi-user.target.wants` symlink under `/etc/`, which gets picked up on first boot via the 3-way merge).

## 7. First-boot bootstrap design

### 7.1 Layout

```
/usr/share/bootstrap/
├── lib/
│   └── common.sh            # logging, hardware detection, LUKS helpers, marker files
├── run-all.sh               # orchestrator; --check does dry-run verification
├── 00-sanity.sh
├── 05-firmware-update.sh
├── 10-luks-tpm2.sh
├── 11-luks-fido2.sh
├── 12-luks-recovery.sh
├── 13-luks-wipe-installer.sh
├── 30-fingerprint-enroll.sh
└── 40-framework-ec.sh
```

### 7.2 `--check` semantics (uniform across all scripts)

- **exit 0** — already done OR hardware not applicable (skip).
- **exit 1** — applicable but not yet done; needs running.
- **exit >1** — hard error (missing expected tool, malformed state).

`run-all.sh --check` treats exit 0 as pass (does not differentiate skip from done for the overall verdict; individual script output makes the distinction visible to humans).

### 7.3 Hardware detection (in `lib/common.sh`)

- `is_framework_laptop` — DMI `sys_vendor == "Framework"`
- `is_vm` — DMI matches QEMU/KVM/VMware/innotek/Xen/Microsoft
- `has_tpm2` — `/dev/tpm*` present AND `tpm2_pcrread sha256:7` succeeds
- `has_yubikey` — `ykman list` non-empty
- `has_fingerprint_reader` — `lsusb` matches Goodix/Synaptics/Validity
- `has_encrypted_root` — `findmnt /` points at a `/dev/mapper/luks-*` device

Scripts gate on these and `skip`+`exit 0` if prerequisites absent. Makes CI in a VM possible.

### 7.4 Step order & intent

| Step | Action | Gates |
|---|---|---|
| `00-sanity.sh` | Verify tooling present; log kernel, bootc image ref; warn on missing non-critical tools. | always runs |
| `05-firmware-update.sh` | `fwupdmgr refresh && fwupdmgr update -y --no-reboot-check`. Skip in VM. | `!is_vm` |
| `10-luks-tpm2.sh` | `systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7+11`; patch `/etc/crypttab` with `tpm2-device=auto`. | `has_encrypted_root && has_tpm2` |
| `11-luks-fido2.sh` | `systemd-cryptenroll --fido2-device=auto --fido2-with-client-pin=yes --fido2-with-user-presence=yes`. | `has_encrypted_root && has_yubikey` |
| `12-luks-recovery.sh` | `systemd-cryptenroll --recovery-key`; display once; require typed confirmation `saved`. | `has_encrypted_root` |
| `13-luks-wipe-installer.sh` | Refuse unless TPM2 + FIDO2 + recovery all present. Then `cryptsetup luksKillSlot 0`. | all three enrolled |
| `30-fingerprint-enroll.sh` | `fprintd-enroll -f right-index-finger`. | `has_fingerprint_reader` |
| `40-framework-ec.sh` | `framework_tool --charge-limit 80`. | `is_framework_laptop` |

Steps 20–29 are reserved for future flatpak/desktop setup that may come back to the image; currently unused.

### 7.5 `run-all.sh` step discovery

Use glob `[0-9]*.sh` rather than `0*.sh 1*.sh 3*.sh 4*.sh` — picks up any future numbered step (including a resurrected 2x) without another Containerfile edit.

## 8. Installer (kickstart)

### 8.1 `config.toml.in` — authoritative unattended-install template

Rendered to a real `config.toml` before invoking `bootc-image-builder --type anaconda-iso`. Produces an ISO with the image embedded (no network required during install). Highlights:

- Partitioning: `zerombr`, GPT, `reqpart --add-boot`, single btrfs root on LUKS2/argon2id.
- Locale: `en_GB.UTF-8`, PL keyboard, Europe/Warsaw, UTC.
- User: `netf` + `wheel`, password hash for throwaway `CHANGE_ME!!!` (documented; regenerate via `openssl passwd -6 'your-pw'`, not the deprecated Python `crypt` module).
- Services enabled: `sshd`, `tailscaled`.
- `firstboot --disable` (Anaconda's firstboot, not ours).
- `reboot --eject`.

Users module disabled (`org.fedoraproject.Anaconda.Modules.Users`) because user is created via kickstart.

### 8.2 `config-ci.toml` — CI qcow2 variant

Separate file so the unattended-with-LUKS story stays clean. Contents:

- No LUKS (raw qcow2 with SSH key authentication).
- `netf` + `root` users with the CI ed25519 pubkey injected.
- Kernel append: `console=ttyS0,115200` for serial log capture.

## 9. Signature enforcement

Adopted from Aurora/Bluefin/Bazzite pattern.

### 9.1 Files baked into image

- `/usr/etc/containers/pubkey.pem` — copy of `cosign.pub` from repo root.
- `/usr/etc/containers/policy.json`:
  - `ghcr.io/netf` → `sigstoreSigned`, keyPath = embedded pubkey, matchRepository.
  - `quay.io/fedora-ostree-desktops`, `quay.io/centos-bootc` → `insecureAcceptAnything`.
  - Default → `insecureAcceptAnything` (so random podman pulls still work).
- `/usr/etc/containers/registries.d/ghcr-io-netf.yaml` — `use-sigstore-attachments: true`.

### 9.2 Build-time verification

Containerfile asserts policy references the embedded key:
```dockerfile
RUN set -e; \
    grep -q "/usr/etc/containers/pubkey.pem" /usr/etc/containers/policy.json && \
    test -f /usr/etc/containers/pubkey.pem
```

### 9.3 Day-2 enforcement

User runs `bootc switch --enforce-container-sigpolicy <ref>` for major version jumps (F44 → F45). `bootc upgrade` checks the policy automatically via `bootc-fetch-apply-updates`.

### 9.4 Key generation

`scripts/bootstrap-cosign.sh` — one-shot helper:
1. Runs `cosign generate-key-pair`.
2. Prints `cosign.pub` → commit to repo.
3. Prints `cosign.key` contents (b64) + password → paste into GitHub Actions secrets `COSIGN_PRIVATE_KEY` and `COSIGN_PASSWORD`.
4. Reminds to store `cosign.key` in password manager and delete the local file.

## 10. CI/CD design

`.github/workflows/build.yml` — three sequential jobs.

### 10.1 Job `lint` (every PR + push)

- `hadolint Containerfile`
- `shellcheck -x bootstrap/**/*.sh scripts/*.sh`
- `bash -n` on every shell script (parse check)
- `yamllint .github/workflows/ *.yaml *.yml` (relaxed line length)
- TOML parse on rendered `config.toml.in` output plus `config-ci.toml`

Gate for `build` and `e2e-vm`.

### 10.2 Job `build` (main push + nightly + workflow_dispatch; needs lint)

1. Free runner disk space (bootc build is ~8GB intermediate).
2. Install podman + cosign.
3. Login to ghcr.io via `GITHUB_TOKEN`.
4. `podman build --build-arg FEDORA_VERSION=$V -t $IMAGE_REF .`
5. `podman run --rm $IMAGE_REF bootc container lint`.
6. **Smoke test** inside the container:
   - Every expected binary present: `chezmoi mise alacritty distrobox tailscale tpm2_pcrread ykman fido2-token fwupdmgr framework_tool fprintd-enroll sbverify restic bpftool bpftrace kdeconnectd iio-sensor-proxy`.
   - Every bootstrap script exists, is executable, parses via `bash -n`.
   - `/usr/lib/bootc/kargs.d/10-fw13.toml` present with expected kargs.
   - `systemctl is-enabled netf-bootstrap.service`.
   - `/usr/etc/containers/policy.json`, `pubkey.pem`, `registries.d/*.yaml` all present and cross-referenced.
   - **Negative assertions**: `eza`, `bat`, `rg`, `fd`, `jq` NOT present.
   - **Initramfs contents**: `lsinitrd /usr/lib/modules/*/initramfs.img | grep -E 'tpm2|cryptsetup|fido2'` — guards the "dracut didn't run" regression.
7. On `refs/heads/main` only:
   - `podman push`.
   - Resolve pushed digest.
   - `cosign sign --yes --key <secret>` the digest.

### 10.3 Job `e2e-vm` (main push + nightly; needs build)

1. Free runner disk space.
2. Install `qemu-system-x86`, `qemu-utils`, `ovmf`, `swtpm`, `swtpm-tools`, `podman`, `netcat`, `openssh-client`.
3. Verify `/dev/kvm` accessible (fail fast with clear error if not).
4. `podman build` image locally (no registry push — tag `localhost/test-image:ci`).
5. Generate CI ed25519 keypair.
6. Write `config-ci.toml` with pubkey.
7. `bootc-image-builder --type qcow2 --config config-ci.toml localhost/test-image:ci`.
8. Start `swtpm` on unix socket.
9. Boot QEMU: KVM, OVMF, emulated TPM2, virtio-net with port-forward 2222→22, serial to file.
10. Poll SSH for up to 5 min (30 × 10s).
11. Inside VM, verify:
    - `bootc status` works.
    - `sudo tpm2_pcrread sha256:7,11` succeeds (validates swtpm + initramfs).
    - `40-framework-ec.sh --check` → skip (not Framework).
    - `30-fingerprint-enroll.sh --check` → skip (no reader).
    - `11-luks-fido2.sh --check` → skip (no YubiKey, no LUKS).
    - `05-firmware-update.sh --check` → skip (VM).
    - `run-all.sh --check` → exit 0 overall.
    - `sbverify --help` succeeds.
12. Shutdown VM cleanly; upload serial log artifact on failure.

### 10.4 What CI cannot verify (manual on real Framework 13 Pro)

- Real YubiKey FIDO2 enrollment.
- Real Goodix fingerprint reader.
- `framework_tool` actually talking to the Framework EC via `/dev/cros_ec`.
- LVFS firmware updates applying to real Framework components.
- Panther Lake–specific kernel behavior and PCR 7 under real Secure Boot.

Documented in README as a short "first boot on real hardware" checklist.

## 11. File inventory

```
fedora-bootc-starter/
├── .github/workflows/build.yml
├── .gitignore
├── .shellcheckrc
├── .yamllint
├── Containerfile
├── Makefile
├── README.md
├── config.toml.in
├── config-ci.toml
├── cosign.pub
├── guide.md                          # kept as reference
├── docs/superpowers/specs/2026-04-23-fedora-bootc-starter-design.md
├── bootstrap/
│   ├── lib/common.sh
│   ├── run-all.sh
│   ├── 00-sanity.sh
│   ├── 05-firmware-update.sh
│   ├── 10-luks-tpm2.sh
│   ├── 11-luks-fido2.sh
│   ├── 12-luks-recovery.sh
│   ├── 13-luks-wipe-installer.sh
│   ├── 30-fingerprint-enroll.sh
│   └── 40-framework-ec.sh
├── files/
│   └── usr/
│       ├── etc/
│       │   ├── motd
│       │   └── containers/
│       │       ├── policy.json
│       │       ├── pubkey.pem        # overwritten at build from repo cosign.pub
│       │       └── registries.d/ghcr-io-netf.yaml
│       └── lib/systemd/system/netf-bootstrap.service
└── scripts/
    ├── bootstrap-cosign.sh
    ├── test-vm.sh
    └── verify-image.sh
```

## 12. Acceptance criteria

The project is done when:

1. `git push origin main` triggers the workflow and **all three jobs (`lint`, `build`, `e2e-vm`) go green**.
2. Nightly scheduled run succeeds for **≥3 consecutive nights** (catches flakes).
3. Signed image is pullable:
   - `podman pull ghcr.io/netf/fedora-bootc-starter:44` succeeds.
   - `cosign verify --key cosign.pub ghcr.io/netf/fedora-bootc-starter:44` succeeds.
4. `make iso` on a Linux workstation produces a bootable ISO.
5. `make test-vm` boots the ISO in QEMU through to a login prompt.
6. On a clean VM boot, `sudo /usr/share/bootstrap/run-all.sh --check` exits 0 with every step reporting `ok` or `skip` (no `needs running` false positives).

Real-hardware acceptance (separate, one-time on actual Framework 13 Pro):

7. USB boots through unattended install to first login in under 10 min.
8. `netf-bootstrap.service` completes on first login; journal shows TPM2 + FIDO2 + recovery enrolled, installer passphrase wiped, fingerprint enrolled, EC charge limit set.
9. Reboot into LUKS → automatic TPM2 unlock works.
10. `cosign verify` on the installed image matches the expected key.

## 13. Security posture

- **Signature enforcement**: `ghcr.io/netf/*` requires valid cosign signature against the key embedded in `/usr/etc/containers/pubkey.pem`. Enforced by `bootc upgrade` and by `bootc switch --enforce-container-sigpolicy` for major version jumps.
- **TPM2 binding**: PCR 7 (secure-boot state) + PCR 11 (kernel/initrd). Detects tampering of either. Kernel updates rebind PCR 11; day-2 command in README.
- **LUKS**: LUKS2, argon2id KDF, discard enabled. Three independent unlock paths after first boot (TPM2 auto, FIDO2/YubiKey with PIN+touch, 48-char recovery key). Installer passphrase (keyslot 0) wiped only after all three enrolled.
- **Cosign keypair**: local (not keyless OIDC); matches single-machine threat model. `cosign.pub` committed so anyone including future-you can verify.
- **Policy default**: `insecureAcceptAnything` — arbitrary podman pulls still work. Only `ghcr.io/netf` is locked down.

## 14. Known residual risks (accepted)

From `guide.md` § "Known sharp edges", carried forward:

- Kernel updates change PCR 11 → TPM2 slot invalidated until re-bind. README documents the one-line command. Not a lockout (FIDO2 + recovery still work).
- `bootc rollback` does not merge `/etc` → rolled-back deployment lacks TPM2 crypttab metadata. Falls back to FIDO2/recovery. Not a lockout.
- LVFS firmware updates may need two boots on first run (EC + BIOS + retimers chain).
- Panther Lake is new silicon — microcode/retimer/TB fixes expected through mid-2026. Weekly `fwupdmgr update` recommended.
- Expansion-card assignment is machine-local state, not part of the image.
- Haptic touchpad requires kernel ≥ 6.15 (F44 default).
- Installer passphrase ships in the ISO as a known SHA-512 hash. Acceptable because USB stays with you and slot 0 is wiped on first boot. Alternative (drop `--passphrase=`, Anaconda prompts once) documented but not default.

## 15. Corrections from guide.md

Concrete deltas applied in this spec vs. the original `guide.md`:

1. **Parameterized Fedora version** (`ARG FEDORA_VERSION=44`) — not hardcoded.
2. **Repo/image name**: `fedora-bootc-starter`, not `kinoite-fw13`.
3. **`starship` removed** from package list (owned by dotfiles).
4. **Kernel version detection** via `rpm -q kernel` (not `ls /usr/lib/modules | head -1`).
5. **Password hash hint** in kickstart comment: `openssl passwd -6` (not removed `crypt` Python module).
6. **motd file** uses plain multiline content, no backslash continuations.
7. **`bootc status` parsing in `00-sanity.sh`**: use `bootc status` plain output with fallback to warn, rather than brittle JSON jq paths.
8. **Dracut module list**: adds `systemd` explicitly.
9. **`--check` semantics**: uniform exit-code convention documented (§7.2).
10. **`run-all.sh` step glob**: `[0-9]*.sh` (inclusive of future numbered steps).
11. **Cosign signing**: always sign the digest, never the tag. Makefile resolves digest after push.
12. **Initramfs content check** added to CI smoke test (new, not in guide).
13. **`.gitignore` + `.shellcheckrc` + `.yamllint`** added (implied by CI but not listed).
14. **`config-ci.toml`** split out from inline workflow heredoc.
15. **systemd unit** moved from Containerfile heredoc to `files/usr/lib/systemd/system/netf-bootstrap.service` (package-path, not `/etc/`, so it's managed by the image and not treated as admin-local state on upgrade).
16. **`scripts/bootstrap-cosign.sh`** added for the keypair setup step.

## 16. Out-of-band prerequisites (one-time)

Before CI will succeed:

1. Run `scripts/bootstrap-cosign.sh` locally → commit `cosign.pub`, store `cosign.key` in password manager.
2. Add GitHub Actions secrets to `github.com/netf/fedora-bootc-starter`:
   - `COSIGN_PRIVATE_KEY` — contents of `cosign.key`.
   - `COSIGN_PASSWORD` — password used during keypair generation.
3. Verify GHCR write permission from the repo (default: GitHub-owned `GITHUB_TOKEN` with `packages: write`).

These are not CI steps; they're human steps documented in README.
