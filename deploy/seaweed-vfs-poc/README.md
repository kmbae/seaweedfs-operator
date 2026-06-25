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
  development. It also injects `HTTP_PROXY=http://127.0.0.1:18083` so `sw-kd`
  volume HTTP reads/writes can be tested through the local RDMA proxy.
- `client-hnode4.yaml`: starts a shell pod on hnode4 with the host mount exposed
  at `/mnt/seaweedvfs`.
- `host-install-workers-job.yaml`: installs the same v0.1.0 DKMS module and
  daemon on hnode1, hnode2, and hnode3.
- `seaweed-vfs-workers.yaml`: runs the kernel mount plus local RDMA proxy on
  hnode1, hnode2, and hnode3. It reuses the `seaweed-vfs-rdma-proxy` ConfigMap
  created by `seaweed-vfs-hnode4.yaml`.
- `seaweed-vfs-rdma-workers.yaml`: replaces the proxy experiment on hnode1,
  hnode2, and hnode3 with an experimental `swvfs-rdma-daemon` that speaks
  `/dev/seaweedvfs` directly. Each pod also starts a node-local RDMA engine and
  mounts the same host path, `/var/lib/seaweedfs-vfs/mnt`.
- `clients-workers.yaml`: starts one shell pod on each worker POC node with the
  host mount exposed at `/mnt/seaweedvfs`.

## RDMA Proxy Experiment

`sw-kd` does not expose an RDMA flag. The POC therefore adds a small local HTTP
proxy in front of its volume-server HTTP path:

```text
sw-kd -> HTTP_PROXY 127.0.0.1:18083 -> local RDMA gateway 127.0.0.1:18081
      -> rdma-sidecar/rdma-engine from the existing seaweedfs-mount DaemonSet
      -> remote volume server
```

The proxy is conservative:

- Range or `?offset=&size=` `GET /<file_id>` requests are converted to
  `/read?file_id=...&volume_server=...`.
- `POST`/`PUT /<file_id>` requests with a body are converted to
  `/write?file_id=...&volume_server=...`.
- Anything else is forwarded to the original volume HTTP endpoint unchanged.

If `sw-kd` does not honor `HTTP_PROXY`, this proxy will receive no traffic. In
that case the next step is a replacement daemon that speaks `/dev/seaweedvfs`
directly and calls the existing RDMA client from its READ/WRITE handlers.

## Apply Order

```sh
microk8s kubectl apply -f deploy/seaweed-vfs-poc/host-install-hnode4-job.yaml
microk8s kubectl -n seaweed-vfs-poc wait --for=condition=complete job/seaweed-vfs-host-install-hnode4 --timeout=20m

microk8s kubectl apply -f deploy/seaweed-vfs-poc/seaweed-vfs-hnode4.yaml
microk8s kubectl -n seaweed-vfs-poc wait --for=condition=ready pod -l app.kubernetes.io/name=seaweed-vfs-node --timeout=5m

microk8s kubectl apply -f deploy/seaweed-vfs-poc/client-hnode4.yaml
microk8s kubectl -n seaweed-vfs-poc wait --for=condition=ready pod/seaweed-vfs-client --timeout=3m
```

For the hnode1-hnode3 expansion, first make sure the CSI mount DaemonSet template
has `rdma.workerSidecar.enablePayloadRDMA=true`, then delete only the old
`seaweedfs-mount` pods on those nodes so they pick up the new template. After
that:

```sh
microk8s kubectl apply -f deploy/seaweed-vfs-poc/host-install-workers-job.yaml
microk8s kubectl -n seaweed-vfs-poc wait --for=condition=complete \
  job/seaweed-vfs-host-install-hnode1 \
  job/seaweed-vfs-host-install-hnode2 \
  job/seaweed-vfs-host-install-hnode3 \
  --timeout=30m

microk8s kubectl apply -f deploy/seaweed-vfs-poc/seaweed-vfs-workers.yaml
microk8s kubectl -n seaweed-vfs-poc wait --for=condition=ready \
  pod -l app.kubernetes.io/name=seaweed-vfs-node-workers --timeout=5m

microk8s kubectl apply -f deploy/seaweed-vfs-poc/clients-workers.yaml
microk8s kubectl -n seaweed-vfs-poc wait --for=condition=ready \
  pod -l app.kubernetes.io/name=seaweed-vfs-client-worker --timeout=3m
```

## Smoke Test

```sh
microk8s kubectl -n seaweed-vfs-poc exec seaweed-vfs-client -- \
  bash -lc 'set -euo pipefail; df -h /mnt/seaweedvfs; echo kernel-vfs-ok > /mnt/seaweedvfs/kernel-vfs-poc.txt; cat /mnt/seaweedvfs/kernel-vfs-poc.txt'
```

## Current Result

Validated on 2026-06-25 against hnode4:

- `seaweedfs-vfs-dkms` and `seaweedfs-vfs` v0.1.0 installed into the hnode4 host.
- `modinfo seaweedvfs` reports module version `0.1.0` for kernel
  `6.8.0-124-generic`.
- `seaweed-vfs-node` is `1/1 Running` and logs:
  - `connected to kernel module via /dev/seaweedvfs`
  - `transport: read()/write()`
  - `mounted SeaweedFS at /var/lib/seaweedfs-vfs/mnt`
- `seaweed-vfs-client` wrote and read
  `/mnt/seaweedvfs/kernel-vfs-poc.txt`.
- The same file is visible from the hnode4 host mount namespace at
  `/var/lib/seaweedfs-vfs/mnt/kernel-vfs-poc.txt`.

This proves the kernel mount path works on one node. It is still TCP/HTTP from
`sw-kd` to SeaweedFS volume servers; the daemon-side RDMA data path remains the
next implementation step.

## RDMA Result

Validated on 2026-06-25 after enabling
`rdma.workerSidecar.enablePayloadRDMA=true` on the CSI mount worker sidecar and
restarting only the hnode4 `seaweedfs-mount` pod:

- `sw-kd` honors the injected `HTTP_PROXY=http://127.0.0.1:18083`.
- The proxy converts SeaweedFS volume HTTP writes to the existing RDMA gateway:
  `POST /write?file_id=...&volume_server=...`.
- The proxy converts full-file reads by resolving `Content-Length` with `HEAD`
  and forwarding `GET /read?file_id=...&offset=0&size=...`.
- hnode4 worker sidecar starts with `enable_payload_rdma=true`.
- hnode4 worker RDMA engine reports `real_rdma=true`.
- Write result:
  - `is_rdma=true`
  - `real_rdma=true`
  - `data_source=remote-rdma-write`
- Read result:
  - `is_rdma=true`
  - `real_rdma=true`
  - `data_source=remote-rdma`
- r7615 volume RDMA engine logs show actual UCX operations:
  - `RDMA GET from peer completed successfully` for write payload transfer.
  - `RDMA PUT to peer completed successfully` for read payload transfer.

This proves the hnode4 kernel mount POC can perform SeaweedFS read/write payload
I/O over RDMA through the proxy path.

## Worker Node RDMA Result

Validated on 2026-06-25 against hnode1, hnode2, and hnode3:

- `seaweedfs-mount` was restarted only on hnode1-hnode3 so those pods picked up
  `rdma.workerSidecar.enablePayloadRDMA=true`; hnode4 was left running.
- `seaweedfs-vfs-dkms` and `seaweedfs-vfs` v0.1.0 installed successfully on:
  - hnode1 kernel `6.8.0-124-generic`
  - hnode2 kernel `6.8.0-124-generic`
  - hnode3 kernel `6.8.0-106-generic`
- `seaweed-vfs-node-workers` is `2/2 Running` on all three nodes and mounts
  `/var/lib/seaweedfs-vfs/mnt`.
- `seaweed-vfs-client-hnode1`, `seaweed-vfs-client-hnode2`, and
  `seaweed-vfs-client-hnode3` can access the host mount at `/mnt/seaweedvfs`.
- Each node wrote a 1 MiB file through the kernel mount, then read a file written
  by a different node to avoid satisfying the read from local page cache.
- Worker sidecar logs on hnode1, hnode2, and hnode3 show both:
  - `RDMA payload write path completed ... real_rdma=true`
  - `RDMA payload read path completed ... real_rdma=true`
- r7615 volume RDMA engine logs show actual UCX operations for the worker test:
  - `RDMA GET from peer completed successfully` for write payload transfer.
  - `RDMA PUT to peer completed successfully` for read payload transfer.

This proves the kernel mount plus local RDMA proxy path works beyond hnode4 and
can do cross-node SeaweedFS read/write payload I/O over RDMA on hnode1-hnode3.

## RDMA Daemon Path

The proxy path proved the data plane but kept `sw-kd` in the middle. The next
worker-node test path removes that layer:

```text
seaweedvfs.ko -> /dev/seaweedvfs -> swvfs-rdma-daemon
  -> local rdma-engine -> r7615 volume rdma-engine/volume server
```

The daemon currently implements the basic metadata calls needed for normal
directory walking plus READ and WRITE. It intentionally falls back to SeaweedFS
HTTP when RDMA is not available, but logs whether the RDMA backend was selected.

To switch hnode1-hnode3 from the old proxy POC to the daemon POC:

```sh
microk8s kubectl delete -f deploy/seaweed-vfs-poc/seaweed-vfs-workers.yaml --ignore-not-found
microk8s kubectl apply -f deploy/seaweed-vfs-poc/seaweed-vfs-rdma-workers.yaml
microk8s kubectl -n seaweed-vfs-poc wait --for=condition=ready \
  pod -l app.kubernetes.io/name=seaweed-vfs-rdma-node-workers --timeout=5m
```

The client pods in `clients-workers.yaml` can be reused because the host mount
path is unchanged.

## RDMA I/O Benchmark Result

Measured on 2026-06-25 with the kernel mount POC path:

```text
hnode2 seaweedvfs mount -> sw-kd HTTP proxy -> local RDMA gateway
  -> hnode2 worker rdma-sidecar/rdma-engine
  -> r7615 volume rdma-engine/volume server
```

Reads were run from hnode3 against files written by hnode2 to reduce local page
cache effects. `seaweedvfs` currently rejects `O_DIRECT`, so fio
`--direct=1` is not usable on this mount. Buffered fio sequential write also
exposes a current stability limit rather than a clean throughput number:

- `fio --direct=1`: fails with `destination does not support O_DIRECT`.
- `fio` 256 MiB sequential write: failed around 33 MiB with
  `Connection timed out`.
- `fio` 16 MiB sequential write with fsync: failed at final sync with
  `Connection timed out`.
- 8 MiB single-file repeated write: first file completed in 146.039 ms, second
  file failed at fsync with `Input/output error`.

Stable microbenchmarks that completed:

| Operation | Unit | Count | Avg Latency | Throughput |
| --- | ---: | ---: | ---: | ---: |
| write | 1 MiB | 10 | 99.668 ms | 10.03 MiB/s |
| read | 1 MiB | 10 | 89.834 ms | 11.13 MiB/s |
| write | 4 MiB | 5 | 97.411 ms | 41.06 MiB/s |
| read | 4 MiB | 5 | 85.075 ms | 47.02 MiB/s |

The benchmark traffic was RDMA-backed:

- hnode2 proxy logs show `RDMA write candidate` for the 1 MiB and 4 MiB writes.
- hnode3 proxy logs show read responses with `rdma=true real=true
  source=remote-rdma`.
- r7615 volume RDMA engine logs show `RDMA GET from peer completed
  successfully` for writes and `RDMA PUT to peer completed successfully` for
  reads.

This means the POC is functionally RDMA-backed, but it is not yet a production
benchmark path. The current limiting factors are the proxy/sidecar handling of
larger buffered write/fsync workloads, lack of `O_DIRECT` support in
`seaweedvfs`, and per-object overhead that dominates small I/O.

## Cleanup

The DaemonSet sets `UNMOUNT_ON_EXIT=1`, so deleting it should unmount the POC
mount from hnode4.

```sh
microk8s kubectl delete -f deploy/seaweed-vfs-poc/client-hnode4.yaml --ignore-not-found
microk8s kubectl delete -f deploy/seaweed-vfs-poc/clients-workers.yaml --ignore-not-found
microk8s kubectl delete -f deploy/seaweed-vfs-poc/seaweed-vfs-workers.yaml --ignore-not-found
microk8s kubectl delete -f deploy/seaweed-vfs-poc/seaweed-vfs-hnode4.yaml --ignore-not-found
```

The host packages are not removed by cleanup. Keep them installed while we are
iterating on the daemon-side RDMA path.
