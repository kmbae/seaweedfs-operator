# SeaweedFS Kernel VFS POC

This directory keeps the first Kubernetes proof-of-concept for `seaweedvfs`,
the SeaweedFS kernel mount. The first target is intentionally one node
(`hnode4`) so we can validate the kernel module, `sw-kd`, mount propagation, and
basic read/write behavior without changing the Slurm workload path.

## Why This Path

`seaweedvfs` moves the VFS, inode/dentry cache, and page cache into the Linux
kernel. The kernel module does no SeaweedFS networking. Network I/O is handled by
the `sw-kd` userspace daemon over `/dev/seaweedvfs`.

That makes this a better long-term base than FUSE for cached reads and metadata
heavy workloads, but it does not make SeaweedFS RDMA by itself. The RDMA data
path belongs in the daemon side (`sw-kd` or an equivalent daemon/sidecar), while
the kernel module should stay focused on VFS integration.

## Files

- `host-install-hnode4-job.yaml`: installs the official v0.1.0 DKMS module and
  `sw-kd` daemon into the hnode4 host OS through a privileged one-shot Job.
- `seaweed-vfs-hnode4.yaml`: runs the official node container as a privileged
  DaemonSet on hnode4 and mounts SeaweedFS at
  `/var/lib/seaweedfs-vfs/mnt` on that host. The POC sets
  `SEAWEED_DISABLE_ENTERPRISE_MODE=1` because `sw-kd` currently requires a
  SeaweedFS Enterprise license check unless explicitly overridden for
  development.
- `client-hnode4.yaml`: starts a shell pod on hnode4 with the host mount exposed
  at `/mnt/seaweedvfs`.

## Apply Order

```sh
microk8s kubectl apply -f deploy/seaweed-vfs-poc/host-install-hnode4-job.yaml
microk8s kubectl -n seaweed-vfs-poc wait --for=condition=complete job/seaweed-vfs-host-install-hnode4 --timeout=20m

microk8s kubectl apply -f deploy/seaweed-vfs-poc/seaweed-vfs-hnode4.yaml
microk8s kubectl -n seaweed-vfs-poc wait --for=condition=ready pod -l app.kubernetes.io/name=seaweed-vfs-node --timeout=5m

microk8s kubectl apply -f deploy/seaweed-vfs-poc/client-hnode4.yaml
microk8s kubectl -n seaweed-vfs-poc wait --for=condition=ready pod/seaweed-vfs-client --timeout=3m
```

## Smoke Test

```sh
microk8s kubectl -n seaweed-vfs-poc exec seaweed-vfs-client -- \
  bash -lc 'set -euo pipefail; df -h /mnt/seaweedvfs; echo kernel-vfs-ok > /mnt/seaweedvfs/kernel-vfs-poc.txt; cat /mnt/seaweedvfs/kernel-vfs-poc.txt'
```

## Cleanup

The DaemonSet sets `UNMOUNT_ON_EXIT=1`, so deleting it should unmount the POC
mount from hnode4.

```sh
microk8s kubectl delete -f deploy/seaweed-vfs-poc/client-hnode4.yaml --ignore-not-found
microk8s kubectl delete -f deploy/seaweed-vfs-poc/seaweed-vfs-hnode4.yaml --ignore-not-found
```

The host packages are not removed by cleanup. Keep them installed while we are
iterating on the daemon-side RDMA path.
