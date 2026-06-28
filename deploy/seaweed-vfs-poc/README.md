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
- `install-patched-kmod-workers.sh`: uploads the local `seaweedvfs-kmod` source
  into a ConfigMap, builds it on hnode1, hnode2, and hnode3, and installs the
  resulting module so the worker POC can enable read/write RDMA hint bits.
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
microk8s kubectl -n seaweed-vfs-poc delete daemonset seaweed-vfs-node-workers --ignore-not-found
bash deploy/seaweed-vfs-poc/install-patched-kmod-workers.sh
microk8s kubectl apply -f deploy/seaweed-vfs-poc/seaweed-vfs-rdma-workers.yaml
microk8s kubectl -n seaweed-vfs-poc wait --for=condition=ready \
  pod -l app.kubernetes.io/name=seaweed-vfs-rdma-node-workers --timeout=5m
```

The checked-in DaemonSet now targets the kernel-direct RDMA descriptor path. The
kernel module loads with `kernel_rdma_direct_reads=1` and
`kernel_rdma_direct_writes=1`, while legacy `rdma_read_hints` and
`rdma_write_hints` default to `0` so fallback reads/writes do not silently return
to the older hinted payload path.

Apply the DaemonSet as-is and recreate the client pods so they bind the fresh
host mount:

```sh
microk8s kubectl -n seaweed-vfs-poc delete pod -l app.kubernetes.io/name=seaweed-vfs-client-worker --ignore-not-found
microk8s kubectl apply -f deploy/seaweed-vfs-poc/clients-workers.yaml
```

To raise the direct RDMA descriptor threshold for larger-request-only tests:

```sh
microk8s kubectl -n seaweed-vfs-poc set env daemonset/seaweed-vfs-rdma-node-workers \
  RDMA_READ_MIN_SIZE=8388608 \
  RDMA_WRITE_MIN_SIZE=8388608 \
  KERNEL_RDMA_DIRECT_READ_MIN_BYTES=8388608 \
  KERNEL_RDMA_DIRECT_WRITE_MIN_BYTES=8388608
microk8s kubectl -n seaweed-vfs-poc rollout status daemonset/seaweed-vfs-rdma-node-workers --timeout=5m
microk8s kubectl -n seaweed-vfs-poc delete pod -l app.kubernetes.io/name=seaweed-vfs-client-worker --ignore-not-found
microk8s kubectl apply -f deploy/seaweed-vfs-poc/clients-workers.yaml
```

Set the min-size values to `0` only for focused RDMA correctness tests where
every direct descriptor request should be forced through the RDMA backend.

### RDMA Daemon Result

Validated on 2026-06-25 against hnode1, hnode2, and hnode3:

- `seaweed-vfs-rdma-node-workers` runs a node-local `swvfs-rdma-daemon` plus a
  node-local RDMA engine on each worker.
- `df -h /mnt/seaweedvfs` and `ls -la /mnt/seaweedvfs` complete cleanly after
  adding daemon support for `STATFS` and empty xattr defaults.
- The first daemon validation used `--force-rdma=true` because the official
  `seaweedvfs` module does not set the experimental RDMA hint bits. The current
  worker POC expects the patched module from `install-patched-kmod-workers.sh`
  and starts `swvfs-rdma-daemon` without force mode.
- Cross-node write test:
  - hnode1 wrote `/mnt/seaweedvfs/rdma-force-poc-1782394300.bin` (256 KiB).
  - hnode1 daemon logged `RDMA payload write path completed` with
    `real_rdma=true` and `data_source=remote-rdma-write`.
  - r7615 volume RDMA engine logged `RDMA GET from peer completed successfully`.
- Cross-node read test:
  - hnode2 read the same 256 KiB file written by hnode1.
  - hnode2 daemon logged `RDMA payload read path completed` with
    `real_rdma=true` and `data_source=remote-rdma`.
  - r7615 volume RDMA engine logged `RDMA PUT to peer completed successfully`.

This proves the replacement daemon path can do SeaweedFS read and write payload
I/O over real RDMA without the old `sw-kd` HTTP proxy layer.

Validated again on 2026-06-26 with the patched `seaweedvfs` module and the
`swvfs-rdma-daemon` image `kmbae27/rdma-sidecar:swvfs-20260626-8bc56bb9d`:

- hnode1, hnode2, and hnode3 loaded `seaweedvfs` with
  `rdma_read_hints=Y` and `rdma_write_hints=Y` in this historical run.
- The RDMA correctness run temporarily started `swvfs-rdma-daemon` with
  `force_rdma=false`, `read_rdma=true`, `write_rdma=true`, and
  `payload_rdma=true`.
- `mkdir` now persists directories in the SeaweedFS filer format, so a
  directory created on hnode1 is seen as a directory from hnode2.
- Basic `SETATTR` is implemented for mode/uid/gid/size/mtime/atime, so
  workflows such as `touch` and fio file setup no longer fail with
  `Function not implemented`.
- The daemon also handles `RENAME`, `SYMLINK`/`READLINK`, and `MKNOD`, reducing
  the remaining gap from a basic POSIX mount surface.
- At that point the checked-in DaemonSet started with `read_rdma=false`,
  `write_rdma=false`, and `payload_rdma=false`; newer manifests use explicit
  kernel-direct descriptor gates instead of legacy hint defaults.
- hnode1 write and hnode2 read fio runs both logged `real_rdma=true` with
  `data_source=remote-rdma-write` or `data_source=remote-rdma`; the volume-side
  RDMA engine logged matching RDMA GET/PUT completions.

Validated again on 2026-06-26 with RDMA engine image
`kmbae27/rdma-engine:rdma-20260626-e1419d965`:

- The volume-side RDMA engine now scopes UCX peer endpoint cache keys by worker
  address as well as operation, volume, and needle. This prevents a read of the
  same needle from hnode2 and hnode3 from reusing an endpoint created for another
  worker.
- hnode1 wrote an 8 MiB file through `swvfs-rdma-daemon` with
  `data_source=remote-rdma-write` and `real_rdma=true`.
- hnode2 and hnode3 read the hnode1-written file with matching SHA-256 checksums
  and `data_source=remote-rdma`, `real_rdma=true`.
- r7615 volume RDMA engine stayed at restart count 0 and logged successful RDMA
  PUT completions for both worker readers.
- After the correctness run, the live POC DaemonSet was returned to the then
  checked-in safer defaults: `read_rdma=false`, `write_rdma=false`,
  `payload_rdma=false`, `RDMA_READ_MIN_SIZE=8388608`, and
  `RDMA_WRITE_MIN_SIZE=8388608`.

Validated on 2026-06-26 with `swvfs-rdma-daemon` image
`kmbae27/rdma-sidecar:swvfs-20260626-0037bc15` and the patched
`seaweedvfs-kmod` through commit `001ebd2`:

- hnode1, hnode2, and hnode3 were reloaded with `seaweedvfs` srcversion
  `66229F74CC4B242F148C26A`.
- Reloading the kernel module requires dropping all hnode1-hnode3 client pods
  and the worker DaemonSet first. Installing the `.ko` file alone is not enough
  if the old module is still referenced by active mounts.
- POSIX smoke passed on the kernel mount: non-empty `rmdir` fails correctly,
  `truncate` trims to the requested size, and `symlink`, `readlink`, `mkfifo`,
  `unlink`, and `rmdir` work.
- Cross-node xattr smoke passed: hnode1 set `user.swvfs`, hnode2 read it with
  `getxattr` and saw it in `listxattr`.
- The daemon now stores xattrs in filer metadata, enforces `unlink` vs `rmdir`
  directory rules, trims chunks on truncate, and falls back to parent
  `ListEntries` when direct filer lookup reports not found.
- The kmod now exposes opt-in `dcache_trace` logs and dcache counters for
  `lookup`, `d_revalidate`, `d_weak_revalidate`, negative dentry invalidation,
  and readdir cache priming.
- Cross-node negative lookup refresh passed: hnode2 first looked up a missing
  file, hnode1 created the file afterwards, and hnode2 then read it directly
  without parent `readdir`. hnode2 counters moved from `lookup_calls=2`,
  `lookup_success=1`, `lookup_enoent=1` to `lookup_calls=3`,
  `lookup_success=2`, `lookup_enoent=1`, proving the plain-open refresh path
  issued a fresh filer lookup and found the remote create.

Validated again on 2026-06-26 with patched `seaweedvfs-kmod` through commit
`8c31edc`:

- hnode1, hnode2, and hnode3 were reloaded with `seaweedvfs` srcversion
  `D6EE5DA5E3A4DC301E5EE57`.
- The kmod now refreshes positive dentries on file open, refreshes stale attrs
  from `getattr` and `read_iter`, and invalidates the page cache when remote
  size/mtime/ctime changes. `attr_cache_ttl_ms` is a runtime module parameter
  for tuning correctness vs refresh traffic.
- SeaweedFS can return a different remote inode number for the same path after
  create/recreate. The kmod now counts this via `positive_refresh_ino_changed`
  and treats the path's latest attrs as authoritative instead of returning
  `ESTALE`.
- Cross-node cache smoke passed: hnode2 saw hnode1 delete as ENOENT, saw hnode1
  rename old path as ENOENT and new path as readable, saw truncate from 26 bytes
  to 5 bytes immediately, and saw same-size overwrite update from `AAAA` to
  `BBBB`.
- Negative dentry regression smoke passed again: hnode2 first cached a missing
  path, hnode1 created it, and hnode2 then read it directly.
- hnode2 coherency counters after the run included `positive_refresh_enoent=2`,
  `remote_attr_size_changed=1`, and `remote_attr_cache_invalidated=2`, matching
  the delete/rename/truncate/overwrite tests.
- POSIX smoke passed for `chmod`, `symlink`, `readlink`, symlinked read,
  `rename`, `unlink`, and `rmdir`.

Validated hardlink support on 2026-06-26 with `swvfs-rdma-daemon` image
`kmbae27/rdma-sidecar:swvfs-20260626-fad5cb00` and SeaweedFS commit
`fad5cb001`:

- `ln base hard` now succeeds through the kernel mount.
- hnode1 saw `base` and `hard` with `nlink=2` and the same inode inside that
  mount.
- Fresh lookups on hnode2 and hnode3 saw both paths with `nlink=2` and the same
  hardlink-ID-derived inode.
- hnode2 wrote through the `hard` path, then read the updated content through
  `base`; hnode1 also read the hnode2 update through `base`.
- A node that created the hardlink can keep its pre-link inode number until
  remount, but both hardlink paths stay wired to the same local inode and fresh
  lookups derive inode identity from `HardLinkId`.

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

### RDMA Daemon fio Comparison

Measured on 2026-06-26 through the replacement daemon path:

```text
seaweedvfs.ko -> /dev/seaweedvfs -> swvfs-rdma-daemon
  -> local rdma-engine or HTTP fallback
  -> SeaweedFS volume server
```

Both runs used fio 3.36 with `--ioengine=sync --direct=0 --iodepth=1
--bs=256k --size=8m`. Writes ran on hnode1 and reads ran from hnode2 against
the hnode1-written file.

| Path | Operation | Throughput | Avg Completion Latency |
| --- | --- | ---: | ---: |
| RDMA hint path | write | 2440 KiB/s | 104.92 ms |
| RDMA hint path | read | 2438 KiB/s | 104.98 ms |
| TCP fallback | write | 58.4 MiB/s | 4.25 ms |
| TCP fallback | read | 70.2 MiB/s | 3.56 ms |

The RDMA hint path is functionally correct but currently much slower than TCP
fallback for this fio shape. The logs show the RDMA path spends roughly 95-100 ms
per 256 KiB chunk in the current daemon/engine protocol, while TCP fallback
completes the same chunk size in a few milliseconds. The next optimization target
is therefore not InfiniBand bandwidth; it is reducing per-chunk RDMA session and
control-plane overhead, batching larger transfers, and avoiding one remote
handshake per 256 KiB request.

### RDMA Write-Back Coalescing

Validated on 2026-06-27 with `swvfs-rdma-daemon` image
`kmbae27/rdma-sidecar:swvfs-20260627-writeback-3b64cc1f`.

The daemon now buffers sequential writes per file and flushes them on
`FLUSH`/`RELEASE` or when the pending range reaches 32 MiB. This keeps the
kernel ABI at 8 MiB per `WRITE` upcall while reducing SeaweedFS assign/write
metadata operations and RDMA payload handshakes.

```text
512 MiB, bs=8M, hnode1 write -> hnode2 read
before write-back: write 6417 ms, read 6310 ms
after write-back:  write 3453 ms, read 3440 ms
```

Logs confirmed 16 coalesced 32 MiB writes with `data_rdma=true` and
`real_rdma=true`; reads still use 64 separate 8 MiB RDMA payload requests. A
64 MiB random cross-node checksum test also passed:

```text
sha256=00406923d41af513ffefad422b4138f364983993830b9be24014e132cccb2eb2
write_elapsed_ms=460
read_elapsed_ms=330
```

This was an improvement, not the final RDMA endpoint. The next bottlenecks were
userspace IPC copies, MessagePack frame copies, per-read 8 MiB sessions, and the
remote sidecar's HTTP write into the volume server.

### Direct Volume gRPC Writes

Validated on 2026-06-27 with RDMA engine image
`kmbae27/rdma-engine:rdma-20260627-volgrpc-9cb5ef4e` and Helm release
`seaweedfs` revision 36.

The volume-side RDMA engine now persists remote writes through the SeaweedFS
volume server gRPC `WriteNeedleBlob` API instead of staging through the local
sidecar HTTP endpoint. The volume pod exposes `VOLUME_SERVER_GRPC_URL` as
`http://$(POD_IP):8444`, which maps to the volume server gRPC port.

Corrected cross-node smoke test on the real kernel mount:

```text
hnode1 write -> hnode2/hnode3 read
path=/var/lib/seaweedfs-vfs/mnt/rdma-volgrpc-20260627-0441/payload.bin
size=64 MiB
sha256=424671d11a5a738b7e26b3223d844b209456325d61f431b7d456cd5224e0f8a0
```

Logs confirmed:

- Write path: `remote-rdma-write:volume-grpc`, `data_rdma=true`,
  `real_rdma=true`.
- Read path: `remote-rdma:volume-grpc-range`, `data_rdma=true`,
  `real_rdma=true`.
- Volume engine: successful RDMA GET for write ingest and RDMA PUT for reads,
  with no `direct volume gRPC write failed` fallback.

The remaining large costs are now in kernel module to daemon copies, daemon to
engine IPC framing/copies, per-request RDMA/session control overhead, and
SeaweedFS metadata/update semantics. The old remote HTTP staging step is no
longer on the happy path.

### RDMA Production Gate

The combined gate is:

```sh
deploy/seaweed-vfs-poc/run-rdma-production-gate.sh
```

It validates:

- hnode1 write plus hnode2/hnode3 checksum reads on the kernel mount.
- fio sequential write/read through the RDMA-backed mount.
- worker and volume logs proving `remote-rdma-write:volume-grpc` and
  `remote-rdma:volume-grpc-range`.
- `pjdfstest` core POSIX syscall subset.
- RDMA worker restart failover on hnode2, followed by checksum read.

Current status on 2026-06-27:

```text
SMOKE_SIZE_MB=64 FIO_SIZE=64M RUN_FIO=true RUN_PJDFSTEST=true RUN_FAILOVER=true
Result: PASS
fio write: 86.3 MiB/s
fio read:  59.0 MiB/s
pjdfstest: Files=6, Tests=96, Result=PASS
failover: hnode2 RDMA worker restarted and checksum read passed
```

### PJDFSTEST POSIX Gate

Production readiness should use
[pjd/pjdfstest](https://github.com/pjd/pjdfstest) as the POSIX syscall
regression gate. Upstream `pjdfstest` expects tests to run from the filesystem
under test, but the Seaweed VFS POC keeps the compiled helper outside the mount
and only runs the test working directory on `/mnt/seaweedvfs`. This avoids
mixing `exec`/mmap behavior of the helper binary with the filesystem syscall
semantics under test.

Fast core gate:

```sh
deploy/seaweed-vfs-poc/run-pjdfstest-vfs.sh
```

Full gate for a production candidate:

```sh
PJDFSTEST_TESTS=tests/ deploy/seaweed-vfs-poc/run-pjdfstest-vfs.sh
```

Current status:

- Core subset passed on 2026-06-27 with the RDMA write-back image:
  `Files=6`, `Tests=96`, `Result=PASS`.
- Full `tests/` passed on 2026-06-27 with the RDMA write-back image:
  `Files=238`, `Tests=8798`, `Result=PASS`, `180 wallclock secs`.
- `pjdfstest` does not cover every distributed filesystem behavior; lock and
  rename concurrency still need separate stress tests.

## Current Development Direction

The current final POC shape is:

1. Keep `seaweedvfs` as the long-term mount base so Linux owns VFS caching,
   dentries, inodes, and page cache behavior.
2. Move file payload data through explicit kernel-direct RDMA descriptor opcodes,
   not sidecar HTTP proxy calls or legacy hint fallback.
3. Keep TCP fallback available until the full fio, `pjdfstest`, and failover
   matrix passes at production sizes.
4. Treat RDMA as a descriptor-gated backend with matching kernel and daemon
   `*_MIN_SIZE` thresholds while the data-plane overhead is reduced.
5. Make the next RDMA work about protocol shape: volume-server-native write
   descriptors, persistent sessions, fewer per-chunk handshakes, registered
   daemon/engine buffers, and a cleaner zero-copy-ish daemon protocol.

## Cleanup

The DaemonSet sets `UNMOUNT_ON_EXIT=1`, so deleting it should unmount the POC
mount from hnode4.

```sh
microk8s kubectl delete -f deploy/seaweed-vfs-poc/client-hnode4.yaml --ignore-not-found
microk8s kubectl delete -f deploy/seaweed-vfs-poc/clients-workers.yaml --ignore-not-found
microk8s kubectl delete -f deploy/seaweed-vfs-poc/seaweed-vfs-rdma-workers.yaml --ignore-not-found
microk8s kubectl delete -f deploy/seaweed-vfs-poc/seaweed-vfs-workers.yaml --ignore-not-found
microk8s kubectl delete -f deploy/seaweed-vfs-poc/seaweed-vfs-hnode4.yaml --ignore-not-found
```

The host packages are not removed by cleanup. Keep them installed while we are
iterating on the daemon-side RDMA path.
