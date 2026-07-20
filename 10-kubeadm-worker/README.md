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

`K8S_MINOR`/`CRIO_MINOR` (default `v1.36`) must match and be bumped together.
Update Kubernetes by rebuilding the image, not `dnf update` on a node.

## What it sets up

- containerd (from Docker's EL repo; Rocky 10 doesn't ship it) with CRI enabled
  and systemd cgroup driver, kubelet/kubeadm/kubectl, kubeadm preflight deps,
  SELinux permissive (per kubeadm docs).
- Kernel modules (`overlay`, `br_netfilter`, `iscsi_tcp`) and k8s sysctls as
  `/usr` drop-ins.
- Longhorn host deps: `iscsi-initiator-utils` (iscsid enabled, unique
  InitiatorName generated on first boot), `cryptsetup`, `device-mapper`. NFSv4
  client is already in the base.
- `containerd`, `kubelet`, `iscsid` enabled; `bootc-fetch-apply-updates.timer`
  masked so nodes don't self-reboot out from under Kubernetes.

## Join (one-time per node)

```bash
cd ansible
cp inventory.example.ini inventory.ini   # edit for your hosts
ansible-playbook -i inventory.ini join-worker.yml
```

Kubelet credentials persist in `/var`, so a node stays joined across OS
upgrades. Only re-join if a node is rebuilt with `/var` wiped.

## Updating a joined node

Timer is masked, so update deliberately: `kubectl cordon` + `drain`, then
`bootc upgrade` and reboot, then `uncordon`. [kured](https://kured.dev)
automates this one node at a time at fleet scale.

## Notes

- CNI plugins are installed by your CNI DaemonSet at runtime, not baked here.
- Longhorn requires SELinux considerations on Rocky; keep it permissive (as set)
  or follow the Longhorn SELinux KB if you re-enable enforcing.
- Not boot-tested into a live cluster; treat the first real `kubeadm join` as
  the validation.
