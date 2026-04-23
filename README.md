# fedora-bootc-starter

Signed Fedora Kinoite bootc image + unattended installer for the Framework Laptop 13 Pro (Panther Lake). Built nightly in CI, smoke-tested and end-to-end tested in a QEMU VM with an emulated TPM2 before every push.

Companion to [netf/dotfiles](https://github.com/netf/dotfiles). This image is the minimum host foundation; everything user-facing (flatpaks, dev languages, toolbox, modern CLI) lives in dotfiles.

## Image

```text
ghcr.io/netf/fedora-bootc-starter:44
```

Signed with cosign; key committed at `cosign.pub`. Verify any pull with:

```bash
cosign verify --key cosign.pub ghcr.io/netf/fedora-bootc-starter:44
```

## Quickstart (day 0, fresh laptop)

On a Linux workstation:

```bash
export INSTALL_LUKS_PASSPHRASE='temporary-luks-passphrase'
make iso
make usb DEV=/dev/sdX
```

`make iso` renders a temporary installer config from `config.toml.in`. For the local path, only `INSTALL_LUKS_PASSPHRASE` is required. `ADMIN_PASSWORD_HASH` defaults to the documented throwaway `CHANGE_ME!!!` hash unless you override it.

If you do want to override the admin hash, export it in the shell first so the `$` characters survive intact:

```bash
export ADMIN_PASSWORD_HASH='$6$...'
make iso
```

On the Framework 13 Pro:

1. BIOS: confirm Intel PTT (TPM2) on, Secure Boot on.
2. Boot the USB from the F12 boot menu. The install is unattended and should finish in about five minutes without network access.
3. Reboot and enter the throwaway installer passphrase once.
4. `netf-bootstrap.service` runs on first login: LVFS firmware -> TPM2 -> FIDO2 -> recovery key -> wipe installer password -> fingerprint -> EC charge limit.
5. The `motd` prints the dotfiles handoff: `curl -fsLS https://raw.githubusercontent.com/netf/dotfiles/main/install.sh | bash`.

## Day 2

```bash
bootc upgrade
systemctl reboot

bootc rollback
systemctl reboot

sudo /usr/share/bootstrap/run-all.sh --check
```

After a kernel update, PCR 11 changes. Re-bind TPM2:

```bash
DEV=$(findmnt -no SOURCE / | xargs cryptsetup status | awk '/device:/ {print $2}')
sudo systemd-cryptenroll "$DEV" --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7+11
```

Major Fedora jump (F44 -> F45):

```bash
bootc switch --enforce-container-sigpolicy ghcr.io/netf/fedora-bootc-starter:45
systemctl reboot
```

## What's in the image

Minimal host foundation only. The package list is authoritative in `Containerfile`; design rationale lives in [`docs/superpowers/specs/2026-04-23-fedora-bootc-starter-design.md`](docs/superpowers/specs/2026-04-23-fedora-bootc-starter-design.md).

In the image: `git`, `chezmoi`, `mise`, `alacritty`, `podman-compose`, `distrobox`, `tailscale`, `wireguard-tools`, `tpm2-tools`, `yubikey-manager`, `fido2-tools`, `fprintd`, `sbsigntools` (`sbverify`/`sbsign`), `iio-sensor-proxy`, `fwupd`, `framework_tool` (built from source), `kdeconnectd`, `jetbrains-mono-fonts-all`, `fira-code-fonts`, `bpftool`, `bpftrace`, `kernel-tools`, `restic`.

Deliberately not in the image and owned by dotfiles: `starship`, `eza`, `bat`, `ripgrep`, `fd`, `jq`, `yq`, `gh`, `just`, `fzf`, `delta`, `zoxide`, flatpaks, language runtimes, and toolbox contents.

## First-time setup for maintainers

Before CI can succeed:

1. Generate a cosign keypair:

```bash
./scripts/bootstrap-cosign.sh
git add cosign.pub && git commit -m "chore: add cosign public key"
```

2. Add GitHub Actions secrets at `Settings -> Secrets and variables -> Actions`:

- `COSIGN_PRIVATE_KEY` - contents of `cosign.key`
- `COSIGN_PASSWORD` - password from keypair generation

3. Delete the local `cosign.key` after storing it offline in a password manager.

## Development

- Lint locally with `make lint`. CI mirrors those checks.
- Full build is `make build && make inspect`, but it requires a Linux host.
- VM end-to-end test is `make test-vm`, which boots the ISO in QEMU under `swtpm`.

CI matrix:

| Job | Runs | What it checks |
| --- | --- | --- |
| `lint` | every PR + push | hadolint, shellcheck, bash -n, yamllint, TOML parse |
| `build` | main + nightly + dispatch | `podman build`, `bootc container lint`, smoke tests, initramfs contents, negative assertions. On main: push and cosign sign the digest. |
| `e2e-vm` | main + nightly | qcow2 via bootc-image-builder, boot in QEMU with swtpm, SSH in, verify TPM2, run bootstrap `--check`, verify hardware gates skip. |

Manual-only checks on real Framework 13 Pro hardware:

- Real YubiKey FIDO2 enrollment
- Real Goodix fingerprint enrollment
- `framework_tool` talking to the real EC
- LVFS firmware actually applying
- Panther Lake kernel behavior under real Secure Boot

## Known sharp edges

See [`docs/superpowers/specs/2026-04-23-fedora-bootc-starter-design.md`](docs/superpowers/specs/2026-04-23-fedora-bootc-starter-design.md) section 14 for the full list. The most common surprises:

- Kernel updates change PCR 11, so TPM2 auto-unlock breaks until re-bind. That is not a lockout; FIDO2 and recovery still work.
- `bootc rollback` does not merge `/etc`, so the rolled-back deployment may lack TPM2 crypttab metadata and fall back to FIDO2 or recovery.
- LVFS may need two boots on the first firmware run because EC, BIOS, and retimer updates can chain.
- Panther Lake is new silicon, so weekly `fwupdmgr update` is recommended through mid-2026.

## References

- Spec: [`docs/superpowers/specs/2026-04-23-fedora-bootc-starter-design.md`](docs/superpowers/specs/2026-04-23-fedora-bootc-starter-design.md)
- Original design notes: [`guide.md`](guide.md)
- Upstream bootc docs: <https://bootc-dev.github.io/bootc/>
- Aurora signature pattern: <https://github.com/ublue-os/aurora>
