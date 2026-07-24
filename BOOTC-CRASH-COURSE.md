# Bootc Crash Course

A practical guide to bootable containers ("image mode" Linux): what they are, how
they differ from a traditional server, how **this repository** builds its Rocky
Linux 10 images and why it makes the choices it does, how to deploy and update
them, and the hard-won gotchas discovered along the way.

---

## 1. What is bootc / image mode?

Traditional Linux servers are **mutable**. You SSH in, run `dnf update`, install
packages, hand-edit configs, and over months every machine drifts into a unique
snowflake. When something breaks you debug it in place, and reproducing a
production box on a test machine is guesswork.

**Bootc treats the entire operating system as a container image.** You build the
OS with a Containerfile, test it, push it to a container registry, and pull it to
hosts. Every host on a given image is byte-for-byte identical. Updates are
atomic: the new OS is staged next to the running one and the machine switches to
it on reboot; if it misbehaves, you reboot back into the previous version.

Red Hat calls this **"image mode"** (as opposed to the traditional **"package
mode"**). It is the model CoreOS and Fedora Atomic pioneered, generalized to use
plain **OCI container images** as the transport. Same Containerfile, same
registry, same `podman pull`, but the artifact is a whole bootable OS instead of
an application.

The mental shift: **you never change a running host. You change the image, roll a
new version, and hosts converge to it.** It is GitOps for the operating system.

---

## 2. How it differs from a traditional system

### vs. traditional package management

| Aspect | Traditional (`dnf`) | Bootc (image mode) |
|---|---|---|
| Unit of change | Individual packages | The entire OS image |
| Atomicity | None (can fail mid-transaction) | Yes (switch on reboot) |
| Rollback | Fragile (`dnf history undo`) | Instant (boot previous deployment) |
| Drift | Every host diverges | Every host identical |
| Testing | Per-package, per-host | The complete image, once |
| `/usr` | Writable | Read-only at runtime |
| Delivery | Package repos | Container registries |
| Reproducibility | Hard | The image *is* the definition |

### vs. application containers

A bootc image looks like a container but behaves like an OS:

| Aspect | App container | Bootc image |
|---|---|---|
| Contains a kernel | No | Yes |
| Runs systemd as PID 1 | Rarely | Yes |
| Manages hardware/bootloader | No | Yes |
| Boots bare metal / VMs | No | Yes |
| Built with a Containerfile | Yes | Yes |
| Lives in an OCI registry | Yes | Yes |

The OCI format is reused purely as a **transport**. The image is pulled like a
container but deployed as a full operating system.

---

## 3. The moving parts

Bootc is an ecosystem of a few tools, each owning one job:

- **bootc**: the host-side agent. Installs an image to disk, switches between
  images, stages upgrades, rolls back, reports status.
- **OCI image**: the delivery format. A standard container image carrying a
  complete Linux tree (kernel, systemd, packages, configs) plus metadata labels
  (`containers.bootc=1`, `ostree.bootable=1`).
- **ostree**: content-addressed filesystem storage. Think "git for filesystem
  trees": every file stored by checksum, snapshots ("commits") of the whole
  `/usr` tree, unchanged files deduplicated across versions, multiple
  deployments kept side by side on disk.
- **rpm-ostree**: the bridge between RPMs and ostree. `rpm-ostree compose
  rootfs` resolves a package manifest, installs RPMs, runs scriptlets, generates
  an initramfs, and emits an ostree-structured rootfs. It is what runs under the
  hood during the build.
- **composefs**: a verified, read-only mount that presents the ostree object
  store as a normal-looking root filesystem. This is what makes `/usr` immutable
  at runtime.
- **bootupd**: manages bootloader (GRUB/shim) updates independently of the OS,
  so a bad update can't leave the machine unbootable.
- **chunkah**: rechunks a composed rootfs into content-addressed OCI layers (see
  §5.3). This repo runs it inside the build.
- **bootc-image-builder**: converts a bootc OCI image into installable disk
  media (ISO, qcow2, raw, AMI, and so on).

A newer capability worth knowing: **logically bound images**, container images
tied to the base OS lifecycle (declared via symlinks in
`/usr/lib/bootc/bound-images.d`), so app containers are pulled and pinned
alongside the OS instead of separately.

---

## 4. The filesystem model

A deployed bootc host is laid out differently from a traditional install:

```
/                Immutable root (composefs mount)
/usr             Immutable OS tree, owned by ostree (updated wholesale on reboot)
/etc             Writable; 3-way merged on every upgrade
/var             Writable; fully persistent, never touched by upgrades
/run, /tmp       Transient (tmpfs); must be empty in the image
/opt -> var/opt  Writable via /var (state overlay may be needed for some apps)
/sysroot         The real disk root; ostree repo + deployments live here
/bin,/lib,/sbin  Symlinks into /usr (usrmerge)
```

What persists across an upgrade, and what doesn't, is the single most important
thing to internalize:

- **`/usr` is replaced wholesale** on reboot from the new image. Never write
  there at runtime (it's read-only anyway). For a transient, non-persistent dev
  tweak there's `bootc usroverlay`, discarded on the next update.
- **`/etc` is 3-way merged.** On upgrade, bootc reconciles the *old image's*
  `/etc` defaults, the *new image's* `/etc` defaults, and *your local changes*
  (the new image's defaults land in `/usr/etc`, and files you edited locally are
  retained). Practically: a service you `systemctl enable` in the image (which
  writes a symlink under `/etc/systemd/system/…wants/`) stays enabled across
  upgrades, and an operator's later `systemctl disable` on a node also persists
  and wins.
- **`/var` is never touched** by upgrades. Databases, container storage
  (`/var/lib/containers`), kubelet state (`/var/lib/kubelet`), home directories
  (`/var/home`, with `/home` symlinked to it), and Longhorn data all live here
  and survive image changes. Anything an app expects pre-created in `/var`
  should be declared with **systemd `tmpfiles.d`**, not baked as image content.
- **`/run` and `/tmp` are transient tmpfs** and must be *empty* in the committed
  image. `bootc container lint --fatal-warnings` fails (`nonempty-run-tmp`) if
  anything is committed there. This bites derived builds in subtle ways (see
  gotchas).

---

## 5. How this repository builds its image (and why)

This repo produces two published images:

- **`rocky-bootc`**: the Rocky Linux 10 bootc **base** image (`10-base/`).
- **`rocky-kubeadm`**: a **derived** Kubernetes node image (`10-kubeadm-worker/`).

The entry point for every build is a **`Justfile`** (`just --list` to see the
recipes). It handles rootful vs rootless automatically (`sudo podman` on Linux,
plain `podman` on macOS), so the same recipes run locally and in CI.

### 5.1 The base image (`10-base/Containerfile`)

The base is a multi-stage Containerfile that composes the OS **and** rechunks it
in one build, using [chunkah](https://github.com/coreos/chunkah).

**Stage `repos`**: pull the official Rocky image only to harvest its repo config
(the `.repo` files, GPG key, and `/etc/dnf/vars/`). Those dnf vars (`$rltype`,
`$contentdir`, and so on) matter: without them the mirrorlist URLs expand to a
literal `$rltype` and 404.

**Stage `builder`** (`FROM quay.io/centos-bootc/centos-bootc:stream10`): swap in
Rocky's repos, then compose the rootfs:

```dockerfile
RUN rm -rf /etc/yum.repos.d/*
COPY --from=repos /etc/yum.repos.d/*.repo /etc/yum.repos.d/
COPY --from=repos /etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-10 /etc/pki/rpm-gpg/
COPY --from=repos /etc/dnf/vars/ /etc/dnf/vars/

# Fetch packages from dl.rockylinux.org directly instead of the mirrorlist.
RUN sed -i 's/^mirrorlist=/#mirrorlist=/; s/^#baseurl=/baseurl=/' /etc/yum.repos.d/rocky*.repo

COPY 10-base/rocky-10.yaml /usr/share/doc/bootc-base-imagectl/manifests/
RUN /usr/libexec/bootc-base-imagectl build-rootfs --reinject \
    --manifest=rocky-10 /target-rootfs
```

Why `centos-bootc:stream10` as the builder? It ships the compose toolchain
(`rpm-ostree`, `bootc-base-imagectl`, dracut, the manifest framework) that
Rocky's plain image does not. We use CentOS bootc's *tooling* with Rocky's
*packages*. `build-rootfs` runs `rpm-ostree compose rootfs` under the hood, and
`--reinject` copies the tooling into the result so derived images can build from
it. The `mirrorlist -> baseurl` sed pins package downloads to
`dl.rockylinux.org` (the mirrorlist service intermittently hands CI an empty
list; see gotchas).

**Stage `unchunked`**: capture the composed tree as a scratch image.

```dockerfile
FROM scratch AS unchunked
COPY --from=builder /target-rootfs/ /
```

**Stage `rechunker`**: run chunkah against that tree (see §5.3).

**Final stage** (`FROM ${FINAL}`, which CI sets to the chunked image): apply the
bootc labels and gate on lint.

```dockerfile
LABEL containers.bootc 1
LABEL ostree.bootable 1
RUN bootc container lint --fatal-warnings
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
```

`bootc container lint --fatal-warnings` fails the build if the image violates
bootc rules; `SIGRTMIN+3` is systemd's clean-shutdown signal; `CMD
["/sbin/init"]` starts systemd as PID 1.

### 5.2 The manifest (`10-base/rocky-10.yaml`)

```yaml
releasever: 10
repos: [baseos, appstream]
packages:
  - rocky-repos
  - vim-enhanced, tmux, wget, bind-utils, rsync   # operator conveniences
  - 'dnf-command(versionlock)'                     # python3-dnf-plugin-versionlock
exclude-packages:
  - kernel-debug-uki-virt
  - kernel-uki-virt
postprocess:
  - # write /usr/lib/bootc/install/20-rocky.toml -> root-fs-type = "xfs"
  - # dnf clean all; rm -rf /var/{log,cache,lib}/*; systemctl preset-all
include:
  - standard/manifest.yaml
```

- `include: standard/manifest.yaml` pulls the upstream "standard" tier (kernel,
  systemd, NetworkManager, podman, openssh, sudo, and more). We deliberately do
  **not** include the CentOS-stream distro layer, so we add `rocky-repos` and
  supply our own repos instead of inheriting subscription-manager/RHEL bits.
- `exclude-packages` drops the UKI kernel variants. Their `%posttrans` calls a
  kernel-install wrapper that isn't present during compose and aborts the x86_64
  base build (upstream centos-stream excludes them for the same reason; since we
  skip that layer, we carry the exclusion ourselves).
- The XFS `postprocess` sets the default install filesystem; the second one
  cleans caches and runs `systemctl preset-all` for default service enablement.

### 5.3 Rechunking with chunkah (in the build)

`build-rootfs` produces the OS as effectively **one giant layer**. Shipping that
means every update re-downloads the whole OS. Rechunking re-splits it into many
content-addressed layers grouped by package, so `bootc upgrade` pulls only the
layers whose packages actually changed.

This repo does it **inside the Containerfile** with chunkah, rather than as a
separate privileged post-build step:

```dockerfile
FROM ${CHUNKAH_IMAGE} AS rechunker
RUN --mount=from=unchunked,src=/,target=/chunkah,ro \
    --mount=type=bind,target=/buildscratch,rw \
    chunkah build \
        --rootfs /chunkah \
        --prune /sysroot/ \
        --max-layers 128 \
        --label ostree.commit- \
        --label ostree.final-diffid- \
        --output oci-archive:/buildscratch/out.ociarchive

FROM ${CHUNKED_IMAGE} AS chunked
```

chunkah reads the `unchunked` rootfs and writes a layered OCI archive to a
scratch mount, then the `chunked` stage imports it (`FROM
oci-archive:...out.ociarchive`). The `just base` recipe wires the scratch mount
(`--volume …:/buildscratch`) and sets `FINAL=chunked` so the released image is
the chunked one. The scratch mount lives at **`/buildscratch`, deliberately not
under `/run`**, so it doesn't leave committed content that would fail
`nonempty-run-tmp` in derived images (see gotchas).

Doing this in-build means one `podman build` yields the content-addressed image;
there's no second `-v /var/lib/containers` privileged rechunk run to orchestrate.

### 5.4 The Justfile entry point

```bash
just base                    # compose + chunk the base for the host arch
just base linux/arm64        # target a specific arch (native on an arm64 host)
just kubeadm                 # build the derived image from a local/pinned base
just media iso               # installer/VM media via bootc-image-builder
```

The Justfile derives `sudo` per-OS (empty on macOS, `sudo` on Linux), so the
nested privileged compose works locally and in CI with the same recipes. Env
knobs (`IMAGE_NAME`, `BASE_REF`, `DISK_IMAGE`, `CACHE`, and so on) override
defaults without editing the file.

### 5.5 The release pipeline (`.github/workflows/release-image.yml`)

Publishing a GitHub Release drives everything. Nothing is hardcoded: registry
and image name come from Actions variables/secrets, and the release tag becomes
the image tag.

1. **`build`**: a matrix over **native** runners (`ubuntu-24.04` for amd64,
   `ubuntu-24.04-arm` for arm64). Each installs `just`, runs `just base`
   (compose + chunk), and pushes an arch-specific tag (`:TAG-amd64`,
   `:TAG-arm64`). Native per-arch is a hard requirement: the nested rpm-ostree
   compose does **not** survive QEMU emulation.
2. **`manifest`**: stitches the two arch tags into one multi-arch manifest
   (`:TAG` and `:latest`) so `bootc upgrade` on either architecture resolves the
   right image from a single tag. It exports `base_ref` for the next job.
3. **`kubeadm`**: builds the derived image via Docker's official
   `docker/github-builder` reusable workflow (BuildKit, native per-arch,
   digest-merged, cosign-signed). It builds `FROM` the **release-tagged** base
   (`base_ref`), not `:latest`, so `rocky-kubeadm:<tag>` is pinned to the exact
   `rocky-bootc:<tag>` it was built on (reproducible, no race with the moving
   `latest`).

### 5.6 The derived image (`10-kubeadm-worker/`): customization by example

This is the canonical "layer your workload on the base" pattern, and it shows
the bootc-specific rules in action:

```dockerfile
ARG BASE_IMAGE=ghcr.io/ssimpson89/rocky-bootc:latest
FROM ${BASE_IMAGE}
```

Because the derived image is a conventional layered build (not a compose), CI
builds it with BuildKit via `docker/github-builder`. Key decisions:

- **Container runtime = containerd from Docker's repo.** Rocky 10 ships neither
  containerd nor a matching CRI-O (CRI-O stable isn't published for v1.33+ on
  `pkgs.k8s.io`), and containerd is what the existing cluster already runs. It's
  configured with the CRI plugin enabled and `SystemdCgroup = true` to match
  kubelet's cgroup driver.
- **Kubernetes from `pkgs.k8s.io`, version-locked.** `kubelet/kubeadm/kubectl`
  are installed and pinned (`dnf versionlock`, plugin baked into the base) so the
  image is reproducible.
- **SELinux set permissive**, per the kubeadm install docs.
- **Longhorn host prerequisites baked in**: `iscsi-initiator-utils` (with a
  unique `InitiatorName` generated on first boot, not baked, so nodes aren't
  clones), `cryptsetup`, `device-mapper`; the NFSv4 client is already in the
  base.
- **Kernel modules and sysctls as `/usr` drop-ins**
  (`/usr/lib/modules-load.d/`, `/usr/lib/sysctl.d/`), not `/etc` edits or runtime
  `modprobe`: `overlay`, `br_netfilter`, `iscsi_tcp`, the k8s bridge/forwarding
  sysctls, and `fs.inotify.max_user_instances`.
- **Services enabled, auto-update masked.** `containerd`, `kubelet`, `iscsid` are
  enabled; `bootc-fetch-apply-updates.timer` is **masked** so a k8s node never
  reboots itself out from under the scheduler (reboots are coordinated, see
  §6.3).
- **`/opt` state overlay** (`ostree-state-overlay@opt.service`) so CNI plugins
  that install into `/opt/cni/bin` at runtime have a writable path.
- **`/var` cleaned** after `dnf` so `bootc container lint` stays green.

`kubeadm join` itself is **not** baked; it's a one-time runtime step per node
(see §6.1).

---

## 6. Using the images

There are two lifecycles: **day 1** (a node first comes into existence) and
**day 2** (an existing node updates). They use different tools.

### 6.1 Day 1: provisioning

**Disk media.** The OCI image isn't directly bootable metal; convert it with
bootc-image-builder. This repo wraps that in `just media`:

```bash
cp config.toml.example config.toml    # add your SSH key (the installed login)
just media anaconda-iso               # Anaconda installer ISO
just media qcow2                      # VM disk image
just media vmdk <image> amd64         # any bib type, explicit image + arch
```

Artifacts land in `output/` renamed to `<image>-<tag>-<arch>-*` so successive
builds don't overwrite each other. Notes that matter:

- A bootc image has **no default login**; the `config.toml` user (SSH key) is
  the only way in. The install won't prompt you to create one.
- The default ISO is **unattended and wipes all disks it sees**. Only boot it on
  disposable disks, or use the interactive/kickstart mode in
  `config.toml.example`.
- Build media on a host of the **target** architecture. Cross-arch works with an
  `arch` argument, but it runs under emulation and is slow/fragile.
- `kubeadm join` is a one-time bootstrap: run `kubeadm token create
  --print-join-command` on a control-plane node, run it on the new node. The
  node's credentials then live in `/var` and survive every OS upgrade, so you
  only re-join if the node is rebuilt with `/var` wiped.

**Directly, on an existing machine:**

```bash
bootc install to-disk /dev/sda --source-imgref <image>   # provision a disk
bootc switch <image>                                     # convert a running host
```

### 6.2 Day 2: updates

```bash
bootc upgrade            # fetch + stage the newer image (no reboot)
bootc upgrade --apply    # fetch, stage, and reboot to apply
bootc upgrade --check    # report whether a newer image exists, change nothing
bootc status             # booted / staged / rollback deployments
bootc rollback           # make the previous deployment the default; reboot to use
```

What happens on upgrade: bootc checks the registry digest, pulls only changed
layers, ostree writes the new deployment *beside* the current one, the bootloader
is pointed at it, and the switch happens atomically on reboot. The old deployment
becomes the rollback target. Nothing on the running system is mutated.

The standard base ships `bootc-fetch-apply-updates.timer` for hands-off
fetch+apply. We **mask it on Kubernetes nodes** on purpose.

### 6.3 Kubernetes specifics

- **Coordinated reboots with kured.** bootc stages an update but only applies it
  on reboot; an uncoordinated reboot on a k8s node is an outage. Run a
  **stage-only** `bootc upgrade` on a timer, then let
  [kured](https://kured.dev) (a DaemonSet) cordon/drain/reboot one node at a time
  under a cluster lock. kured's reboot-sentinel command drives *when*, so wire it
  to a real "reboot needed" signal (a `needs-restarting`-style check exits
  non-zero when a reboot is due; mind the exit-code direction).
- **Longhorn** needs the host prerequisites baked into the image (see §5.6) and
  reboots taken one node at a time so only one replica is ever in flight.
- **HA control plane** must be initialized with a `--control-plane-endpoint` (a
  load balancer or floating VIP such as kube-vip); a single node's own IP can't
  provide HA because it dies with the node.

---

## 7. Hard-won gotchas

Real lessons from building this repo. Most cost a failed CI run to learn.

- **Build multi-arch natively, never via emulation.** The nested rpm-ostree
  compose (and osbuild for disk media) fail or hang under QEMU. Use one native
  runner per arch and merge to a manifest.
- **The CI runner's `buildah` is old (1.33.7).** It cannot parse Containerfile
  heredocs (`RUN cat <<EOF`); it splits them into bogus instructions. Build
  derived images with **BuildKit** (which supports heredocs, as our kubeadm job
  does) or write files with `printf`. Verify with the exact runner versions, not
  just "it works locally."
- **Exclude UKI kernel packages** (`kernel-*-uki-virt`). Their `%posttrans` needs
  a kernel-install wrapper absent during compose and aborts the x86_64 base
  build.
- **Prefer `dl.rockylinux.org` baseurls over the mirrorlist in CI.** The
  mirrorlist service intermittently returns an empty list to runners, failing the
  compose with "No URLs in mirrorlist."
- **`$releasever` is 10.2, not 10, under osbuild.** bootc-image-builder's
  depsolver resolves `$releasever` from `VERSION_ID` (`10.2`), which 404s against
  Docker's repo (only `10` exists). Pin the docker-ce baseurl to the major
  version.
- **Keep `/var`, `/run`, `/tmp` clean or `bootc container lint --fatal-warnings`
  fails.** `dnf` leaves logs and history (`var-log`, `var-tmpfiles`), and stray
  build scratch dirs under `/run` fail `nonempty-run-tmp`. This is exactly why
  chunkah's scratch mount is `/buildscratch` and not `/run/src`. Note
  `/run/secrets` (RHSM) is a live *mount* during the build, you can't `rm` it
  (busy); target the specific leftover instead of `rm -rf /run/*`.
- **Config goes in `/usr` drop-ins.** modules-load.d, sysctl.d, tmpfiles.d, and
  systemd presets in `/usr/lib/...` are image-owned and updated with the image;
  `/etc` edits are for per-node local intent.
- **SELinux + Kubernetes**: kubeadm docs say permissive. Enforcing is possible
  with `container-selinux` plus policy work, but expect to test workloads
  (hostPath, CSI) for denials.
- **swap off for kubelet.** It refuses to start with active swap; watch for
  `zram-generator` pulling in a zram swap device.
- **Digest is not the same as a package change.** Rechunking/rebuilds change the
  image digest with zero package changes. To know if packages actually changed,
  diff the manifests (`rpm -qa`, filter `gpg-pubkey` noise) or `rpm-ostree db
  diff`. Kernel point-release bumps between builds are normal repo drift, not a
  regression.
- **Sign your images.** The kubeadm job produces cosign/provenance attestations
  via keyless OIDC. For public images this is a supply-chain win.

---

## 8. Command reference

```bash
# --- Build (this repo) ---
just base                  # compose + chunk the base for the host arch
just base linux/arm64      # target a specific arch
just kubeadm               # build the derived kubeadm image
just media iso|qcow2|...   # installer/VM media via bootc-image-builder

# --- Deploy ---
bootc install to-disk /dev/sda --source-imgref <image>
bootc install to-filesystem /mnt
bootc switch <image>       # convert a running host

# --- Update ---
bootc upgrade              # fetch + stage
bootc upgrade --apply      # fetch + stage + reboot
bootc upgrade --check      # report availability only
bootc usroverlay           # transient writable /usr (discarded on update)

# --- Rollback / status ---
bootc rollback
bootc status
bootc status --format json

# --- Validate an image / inspect packages ---
bootc container lint --fatal-warnings
rpm-ostree db diff <ref-a> <ref-b>      # package diff between two commits/images
```

---

## 9. Glossary

- **image mode**: running Linux from a container image (vs. "package mode").
- **bootc**: the host agent for installing/updating bootable container images.
- **ostree**: content-addressed store of immutable OS snapshots; git-like.
- **rpm-ostree**: composes RPMs into ostree commits; bridges RPM and ostree.
- **composefs**: verified read-only mount presenting ostree content as `/`.
- **bootupd**: bootloader (GRUB/shim) updater, independent of the OS.
- **bootc-base-imagectl**: orchestrates rpm-ostree to compose the base rootfs.
- **chunkah**: rechunks a composed rootfs into content-addressed OCI layers.
- **bootc-image-builder**: turns a bootc OCI image into disk media (ISO/qcow2/...).
- **rechunking**: splitting the one-layer OS into per-package content-addressed
  layers so updates pull only what changed.
- **deployment**: a specific OS version installed on disk and managed by ostree.
- **staging**: writing a new deployment to activate on next reboot.
- **rollback**: booting the previously-good deployment.
- **3-way merge**: how `/etc` reconciles old defaults, new defaults, and local
  edits on upgrade.
- **logically bound images**: app container images pinned to the base OS
  lifecycle via `/usr/lib/bootc/bound-images.d`.
- **day 1 / day 2**: provisioning a node vs. updating an existing node.
- **kured**: Kubernetes reboot daemon that coordinates node reboots (drains, one
  at a time) for image-mode/bootc updates.
</content>
