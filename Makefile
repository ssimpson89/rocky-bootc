# Override for rootless setups (e.g. podman machine on macOS): make PODMAN=podman
PODMAN ?= sudo podman

IMAGE_NAME = rocky-bootc
VERSION_MAJOR = 10
BUILD_DIR = $(VERSION_MAJOR)-base
PLATFORM = linux/amd64
LABELS ?=

# Disk/installer media (see build-disk.sh for env overrides)
DISK_IMAGE  ?= ghcr.io/ssimpson89/rocky-kubeadm:latest
TARGET_ARCH ?=

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

# Disk/installer media from a bootc image (needs config.toml, see example).
# iso/qcow2 are aliases; any bib type works: make disk TYPE=vmdk
.PHONY: iso qcow2 disk
iso:
	PODMAN="$(PODMAN)" TARGET_ARCH="$(TARGET_ARCH)" ./build-disk.sh anaconda-iso $(DISK_IMAGE)

qcow2:
	PODMAN="$(PODMAN)" TARGET_ARCH="$(TARGET_ARCH)" ./build-disk.sh qcow2 $(DISK_IMAGE)

disk:
	@test -n "$(TYPE)" || { echo "usage: make disk TYPE=<qcow2|anaconda-iso|raw|vmdk|...>"; exit 1; }
	PODMAN="$(PODMAN)" TARGET_ARCH="$(TARGET_ARCH)" ./build-disk.sh $(TYPE) $(DISK_IMAGE)
