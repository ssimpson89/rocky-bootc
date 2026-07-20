# Override for rootless setups (e.g. podman machine on macOS): make PODMAN=podman
PODMAN ?= sudo podman

IMAGE_NAME = rocky-bootc
VERSION_MAJOR = 10
BUILD_DIR = $(VERSION_MAJOR)-base
PLATFORM = linux/amd64
LABELS ?=

# Installer media / disk images (bootc-image-builder)
BIB           = quay.io/centos-bootc/bootc-image-builder:latest
KUBEADM_IMAGE ?= ghcr.io/ssimpson89/rocky-kubeadm:latest
DISK_TYPE     ?= anaconda-iso
BIB_CONFIG    ?= config.toml
OUTPUT        ?= output
TARGET_ARCH   ?=

.ONESHELL:
.PHONY: all
all: rechunk

.PHONY: image
image:
	$(PODMAN) build \
		--platform=$(PLATFORM) \
		--security-opt=label=disable \
		--cap-add=all \
		--device /dev/fuse \
		--iidfile /tmp/image-id \
		$(LABELS) \
		-t $(IMAGE_NAME) \
		-f $(BUILD_DIR)/Containerfile \
		.

.PHONY: rechunk
rechunk: image
	$(PODMAN) run \
		--rm --privileged \
		--security-opt=label=disable \
		-v /var/lib/containers:/var/lib/containers:z \
		quay.io/centos-bootc/centos-bootc:stream10 \
		/usr/libexec/bootc-base-imagectl rechunk \
		localhost/$(IMAGE_NAME):latest localhost/rechunked-$(IMAGE_NAME):latest && \
	$(PODMAN) tag localhost/rechunked-$(IMAGE_NAME):latest localhost/$(IMAGE_NAME):latest && \
	$(PODMAN) rmi localhost/rechunked-$(IMAGE_NAME):latest

# Installer ISO for the kubeadm node image. Needs config.toml (login user).
.PHONY: iso
iso: DISK_TYPE = anaconda-iso
iso: disk

# qcow2 for quick VM testing.
.PHONY: qcow2
qcow2: DISK_TYPE = qcow2
qcow2: disk

# Build DISK_TYPE media from KUBEADM_IMAGE via bootc-image-builder.
# Cross-arch (e.g. amd64 media on an arm64 host): make iso TARGET_ARCH=amd64
.PHONY: disk
disk:
	@test -f $(BIB_CONFIG) || { echo "Missing $(BIB_CONFIG): copy config.toml.example to $(BIB_CONFIG) and add your SSH key."; exit 1; }
	$(PODMAN) pull $(KUBEADM_IMAGE)
	mkdir -p $(OUTPUT)
	$(PODMAN) run --rm --privileged \
		--security-opt label=disable \
		-v $(CURDIR)/$(OUTPUT):/output \
		-v $(CURDIR)/$(BIB_CONFIG):/config.toml:ro \
		-v /var/lib/containers/storage:/var/lib/containers/storage \
		$(BIB) \
		--type $(DISK_TYPE) \
		$(if $(TARGET_ARCH),--target-arch $(TARGET_ARCH)) \
		$(KUBEADM_IMAGE)
	@echo "Done. anaconda-iso -> $(OUTPUT)/bootiso/install.iso ; qcow2 -> $(OUTPUT)/qcow2/disk.qcow2"
