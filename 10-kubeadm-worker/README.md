# rocky-kubeadm

Derived bootc image that turns the Rocky 10 base into a ready-to-join
Kubernetes node (kubeadm/kubelet + containerd), with the kernel config, Longhorn
host dependencies, and services baked in. `kubeadm join` stays a runtime step.

Built from `rocky-bootc:<release tag>`, not `:latest`, so a given
`rocky-kubeadm` tag is pinned to the exact base it was built on.

## Build

```bash
podman build \
  --build-arg BASE_IMAGE=ghcr.io/ssimpson89/rocky-bootc:latest \
  -t rocky-kubeadm:latest \
  -f 10-kubeadm-worker/Containerfile \
  10-kubeadm-worker
```

`K8S_MINOR` (default `v1.36`) selects the Kubernetes package repo. Update
Kubernetes by rebuilding the image with a new value, not `dnf update` on a node.

## What it sets up

- containerd (from Docker's EL repo; Rocky 10 doesn't ship it) with CRI enabled
  and the systemd cgroup driver, plus kubelet/kubeadm/kubectl and kubeadm
  preflight dependencies. SELinux is set permissive, per the kubeadm docs.
- Kernel modules (`overlay`, `br_netfilter`, `iscsi_tcp`, and `i2c_dev`/`msr`)
  and Kubernetes sysctls as `/usr` drop-ins.
- Longhorn (V1) host dependencies: `iscsi-initiator-utils` (iscsid enabled, with
  a unique InitiatorName generated on first boot), `cryptsetup`, and
  `device-mapper`. The NFSv4 client is already in the base.
- `containerd`, `kubelet`, and `iscsid` enabled. `bootc-fetch-apply-updates.timer`
  is masked so nodes don't self-reboot out from under Kubernetes.

## Join to a kubeadm cluster

Joining is a one-time step per node; kubelet and containerd are already enabled
in the image.

On an existing control-plane node, generate a join command:

```bash
kubeadm token create --print-join-command
```

It prints something like:

```bash
kubeadm join <control-plane-endpoint>:6443 --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```

Run that as root on the new node. Once the join completes, the node registers
and becomes Ready after a CNI is present on the cluster.

To join an additional control-plane node for HA (rather than a worker), append
`--control-plane --certificate-key <key>`, where the key comes from
`kubeadm init phase upload-certs --upload-certs` on an existing control-plane
node. This requires the cluster to have been initialized with a
`--control-plane-endpoint` (a load balancer or VIP).

Alternatively, the bundled playbook mints a fresh token and joins every host in
the `workers` group that isn't already a member:

```bash
cd ansible
cp inventory.example.ini inventory.ini   # edit for your hosts
ansible-playbook -i inventory.ini join-worker.yml
```

Kubelet credentials persist in `/var`, so a node stays joined across OS upgrades
and reboots. Re-join only if a node is rebuilt with its `/var` wiped.

## Updating a joined node

The auto-update timer is masked, so update deliberately: `kubectl cordon` and
`kubectl drain`, then `bootc upgrade` and reboot, then `kubectl uncordon`.
[kured](https://kured.dev) automates this one node at a time at fleet scale.

## Notes

- CNI plugins are installed by your CNI DaemonSet at runtime, not baked here.
- Keep SELinux permissive (as set), or follow the Longhorn SELinux guidance if
  you re-enable enforcing.
- The image targets the Longhorn V1 data engine. V2 (SPDK) needs additional
  kernel modules and hugepages that are not configured here.
