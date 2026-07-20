# Rocky Linux Bootable Container (bootc)

Builds Rocky Linux 10 bootable container images using the [bootc
framework](https://containers.github.io/bootc/).

Based on the [CentOS Bootc Base Images](https://gitlab.com/redhat/centos-stream/containers/bootc)
tooling and [bootc-base-imagectl](https://gitlab.com/fedora/bootc/base-images/-/blob/main/bootc-base-imagectl.md).

## Images

- **`rocky-bootc`** (`10-base/`) — the Rocky Linux 10 bootc base image.
- **`rocky-kubeadm`** (`10-kubeadm-worker/`) — a derived Kubernetes node image
  (kubeadm/kubelet + containerd, Longhorn host deps). See
  [`10-kubeadm-worker/README.md`](10-kubeadm-worker/README.md), including how to
  join it to a cluster.

## Prerequisites

* `make`
* `podman` (rootful/sudo for the nested build; override with `PODMAN=podman` for
  a rootless setup such as a podman machine on macOS)
* Sufficient disk space and internet connectivity

## Building the base image

```bash
make                        # build + rechunk rocky-bootc for linux/amd64
make PLATFORM=linux/arm64   # build for aarch64
make image PODMAN=podman    # rootless (e.g. macOS podman machine)
```

### Build variables

* `PLATFORM`: target architecture (`linux/amd64`, `linux/arm64`)
* `IMAGE_NAME`: output image name (default: `rocky-bootc`)
* `VERSION_MAJOR`: Rocky major version (default: `10`); selects `<major>-base/`
* `PODMAN`: podman invocation (default: `sudo podman`)

## Building manually (without make)

Two stages: build the image, then rechunk it.

### 1. Build

```bash
sudo podman build \
  --platform=linux/amd64 \
  --security-opt=label=disable \
  --cap-add=all \
  --device /dev/fuse \
  -t rocky-bootc \
  -f 10-base/Containerfile \
  .
```

The build uses nested containerization (podman-in-podman) because
`bootc-base-imagectl` runs `rpm-ostree` inside the container to compose the
rootfs, which is why the extra flags are required:

* `--security-opt=label=disable`: lets the nested container access the build context.
* `--cap-add=all`: grants the capabilities rpm-ostree needs (mount, chroot, etc.).
* `--device /dev/fuse`: provides FUSE access for ostree/composefs.

### 2. Rechunk

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

Rechunking re-splits the image into roughly 60 content-addressed OCI layers.
Without it the entire OS sits in a single layer, so any change means
re-downloading the whole OS on update. Content-addressed layering groups files
by package, so unchanged RPMs produce the same layer across rebuilds and clients
pull only what changed.

## How it works

The base build is a three-stage process:

1. **repos stage**: extracts Rocky Linux 10 repo configs and GPG keys from the
   official `quay.io/rockylinux/rockylinux:10` image.
2. **builder stage**: uses `quay.io/centos-bootc/centos-bootc:stream10` as the
   build environment and runs `bootc-base-imagectl` with the `rocky-10.yaml`
   manifest to compose the rootfs.
3. **final stage**: assembles a minimal bootc image from scratch with the
   composed rootfs.

`make all` runs the build and the rechunk step.

## Releases

Publishing a GitHub Release triggers `.github/workflows/release-image.yml`,
which:

1. builds `rocky-bootc` natively for `amd64` and `arm64`, then publishes a
   multi-arch manifest tagged with the release tag and `latest`;
2. builds `rocky-kubeadm` on top of that release tag and publishes it as its own
   multi-arch image.

The release tag doubles as the image version. Registry and image names come from
Actions variables, so nothing is hardcoded.

## Disk images

The builds above produce OCI container images, which is what `bootc upgrade`
consumes. To create installable media, use
[bootc-image-builder](https://github.com/osbuild/bootc-image-builder) via the
make targets:

```bash
cp config.toml.example config.toml   # add your SSH key (login user for the installed OS)
make iso                             # installer ISO for the kubeadm node image
make qcow2                           # qcow2 for quick VM testing
```

Both default to `KUBEADM_IMAGE` (override to pin a tag or build the base image
instead). Output lands in `output/`. To build media for a different
architecture than the host (e.g. amd64 media on an arm64 machine), add
`TARGET_ARCH=amd64`; note this runs under emulation, so building on a host of
the target architecture is faster and more reliable.
