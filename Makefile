FEDORA_VERSION ?= 44
FW_TOOL_VERSION ?= v0.4.0
IMAGE_REF      ?= ghcr.io/netf/fedora-bootc-starter:$(FEDORA_VERSION)
BUILDER_IMG    := quay.io/centos-bootc/bootc-image-builder:latest
OUTPUT_DIR     := output
export INSTALL_LUKS_PASSPHRASE ?=
export ADMIN_PASSWORD_HASH ?= $$6$$YdvxSXl6YUHhOzEf$$YTvt9PEWKWpTVcb.Y4N/Qlwp.cpMmQbegc8OIFsturFPjOtuYWw4Uzwy5dHlwNiqqiaMd9mfUlJH6wn.EA1Wo0
export EXTRA_USER_BLOCKS ?=
export EXTRA_KERNEL_APPEND ?=

.DEFAULT_GOAL := help
.PHONY: help lint build inspect push sign iso usb test-vm clean

help:  ## Show this help
	@awk 'BEGIN{FS=":.*?##"; printf "\nTargets:\n"} /^[a-zA-Z_-]+:.*?##/ {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

lint:  ## Lint Containerfile, shell scripts, and YAML
	hadolint Containerfile
	shellcheck -x bootstrap/*.sh bootstrap/lib/*.sh scripts/*.sh
	yamllint .github/workflows/ files/etc/containers/registries.d/
	@echo "lint clean"

build:  ## Build the bootc image locally (requires Linux host)
	sudo podman build \
	  --pull=newer \
	  --build-arg FEDORA_VERSION=$(FEDORA_VERSION) \
	  --build-arg FW_TOOL_VERSION=$(FW_TOOL_VERSION) \
	  -t $(IMAGE_REF) .

inspect: build  ## Smoke test the built image
	sudo podman run --rm $(IMAGE_REF) bootc container lint
	sudo podman run --rm $(IMAGE_REF) bash -c '\
	  set -e; \
	  test -x /usr/share/bootstrap/run-all.sh; \
	  test -f /usr/lib/bootc/kargs.d/10-fw13.toml; \
	  systemctl is-enabled netf-bootstrap.service; \
	  command -v chezmoi mise alacritty distrobox tailscale framework_tool fwupdmgr tpm2_pcrread ykman; \
	  echo "smoke tests passed"'

push: build  ## Push image to GHCR
	sudo podman push $(IMAGE_REF)

sign:  ## cosign sign the pushed image DIGEST (not tag)
	@test -f cosign.key || (echo "ERROR: cosign.key missing - run scripts/bootstrap-cosign.sh" && exit 1)
	DIGEST=$$(sudo podman inspect --format '{{index .RepoDigests 0}}' $(IMAGE_REF)); \
	  test -n "$$DIGEST"; \
	  echo "Signing $$DIGEST"; \
	  cosign sign --yes --key cosign.key "$$DIGEST"

iso: build  ## Build the unattended installer ISO
	mkdir -p $(OUTPUT_DIR)
	@test -n "$$INSTALL_LUKS_PASSPHRASE" || { echo "ERROR: INSTALL_LUKS_PASSPHRASE is required"; exit 1; }
	RENDERED_CONFIG=$$(mktemp "$(PWD)/$(OUTPUT_DIR)/installer-config.XXXXXX.toml"); \
	trap 'rm -f "$$RENDERED_CONFIG"' EXIT; \
	./scripts/render-installer-config.sh > "$$RENDERED_CONFIG"; \
	sudo podman run --rm -it --privileged --pull=newer \
	  --security-opt label=type:unconfined_t \
	  -v /var/lib/containers/storage:/var/lib/containers/storage \
	  -v "$$RENDERED_CONFIG":/config.toml:ro \
	  -v $(PWD)/$(OUTPUT_DIR):/output \
	  $(BUILDER_IMG) \
	  --type anaconda-iso --rootfs btrfs \
	  --config /config.toml \
	  $(IMAGE_REF)
	@echo ""
	@echo "ISO ready: $(OUTPUT_DIR)/bootiso/install.iso"
	@du -h $(OUTPUT_DIR)/bootiso/install.iso

usb:  ## Flash ISO to USB (DEV=/dev/sdX required)
	@test -n "$(DEV)" || { echo "ERROR: DEV=/dev/sdX required"; exit 1; }
	@test -b "$(DEV)" || { echo "ERROR: $(DEV) not a block device"; exit 1; }
	@echo "WILL WIPE $(DEV)"
	@lsblk -o NAME,SIZE,MODEL,MOUNTPOINT $(DEV)
	@read -p "Type YES to flash: " a && [ "$$a" = "YES" ]
	sudo dd if=$(OUTPUT_DIR)/bootiso/install.iso of=$(DEV) bs=4M status=progress oflag=direct conv=fsync
	sync
	@echo "USB ready"

test-vm: iso  ## Boot the ISO in QEMU with swtpm for end-to-end testing
	./scripts/test-vm.sh

clean:
	sudo rm -rf $(OUTPUT_DIR)
