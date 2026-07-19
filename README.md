# Rocky Linux Bootable Container Demo (bootc)

Demo project for building Rocky Linux 9 bootable container images using the [bootc framework](https://containers.github.io/bootc/).

Based on the [CentOS Bootc Base Images](https://gitlab.com/redhat/centos-stream/containers/bootc) tooling and [bootc-base-imagectl](https://gitlab.com/fedora/bootc/base-images/-/blob/main/bootc-base-imagectl.md).

## Prerequisites

* `make`
* `podman` (with root/sudo access for nested containerization)
* Sufficient disk space and internet connectivity

## Building

### Rocky Linux 9 (x86_64)

```bash
make \
  PLATFORM=linux/amd64 \
  IMAGE_NAME=rocky-bootc \
  VERSION_MAJOR=9
```

### Rocky Linux 9 (aarch64)

```bash
make \
  PLATFORM=linux/arm64 \
  IMAGE_NAME=rocky-bootc \
  VERSION_MAJOR=9
```

### Build Variables

* `PLATFORM`: Target architecture (e.g., `linux/amd64`, `linux/arm64`)
* `IMAGE_NAME`: Output container image name (default: `rocky-bootc`)
* `VERSION_MAJOR`: Rocky Linux major version (default: `9`)

## Building Manually (without Make)

If you prefer to run the steps directly, there are two stages: building the image and rechunking it.

### Step 1: Build the image

```bash
sudo podman build \
  --platform=linux/amd64 \
  --security-opt=label=disable \
  --cap-add=all \
  --device /dev/fuse \
  -t rocky-bootc \
  -f 9/Containerfile \
  .
```

The build uses nested containerization (podman-in-podman) because `bootc-base-imagectl` runs `rpm-ostree` inside the container to compose the rootfs. This is why the extra flags are required:

* `--security-opt=label=disable`: Disables SELinux label confinement so the nested container can access the build context.
* `--cap-add=all`: Grants the full capability set needed for rpm-ostree to create the filesystem layout (mount, chroot, etc.).
* `--device /dev/fuse`: Provides FUSE device access for ostree/composefs operations.

### Step 2: Rechunk the image

```bash
sudo podman run \
  --rm --privileged \
  --security-opt=label=disable \
  -v /var/lib/containers:/var/lib/containers:z \
  quay.io/centos-bootc/centos-bootc:stream10 \
  /usr/libexec/bootc-base-imagectl rechunk \
  localhost/rocky-bootc:latest localhost/rechunked-rocky-bootc:latest

sudo podman tag localhost/rechunked-rocky-bootc:latest localhost/rocky-bootc:latest
sudo podman rmi localhost/rechunked-rocky-bootc:latest
```

The rechunk step re-splits the image into roughly 60 content-addressed OCI layers. Without it, the entire OS sits in a single layer from the `COPY --from=builder /target-rootfs/ /` step in the Containerfile.

This matters for updates: when you rebuild after a package update, only the layers containing changed files need to be pulled. With one giant layer, any change means re-downloading the whole OS. Content-addressed layering groups files by package so that unchanged RPMs produce the same layer across rebuilds, making registry distribution and client pulls significantly more efficient.

The rechunk command mounts the host's container storage (`/var/lib/containers`) so it can read the built image and write the rechunked output. The tag and rmi commands then swap the rechunked image into place and clean up the intermediate.

## How It Works

The build is a three-stage process:

1. **repos stage**: Extracts Rocky Linux 9 repository configs and GPG keys from the official `quay.io/rockylinux/rockylinux:9` base image
2. **builder stage**: Uses `quay.io/centos-bootc/centos-bootc:stream10` as the build environment, runs `bootc-base-imagectl` with a Rocky-specific YAML manifest to compose the rootfs
3. **final stage**: Creates a minimal bootc image from scratch with the composed rootfs

The `make rechunk` step (run by default via `make all`) optimizes the image layer structure for efficient OCI distribution.
