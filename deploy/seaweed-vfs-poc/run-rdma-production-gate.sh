#!/usr/bin/env bash
# Validate the Seaweed VFS RDMA data path with smoke I/O, fio, pjdfstest, and
# a daemon restart failover check.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NS="${NS:-seaweed-vfs-poc}"
SEAWEED_NS="${SEAWEED_NS:-seaweedfs}"
CLIENT_LABEL="${CLIENT_LABEL:-app.kubernetes.io/name=seaweed-vfs-client-worker}"
WORKER_LABEL="${WORKER_LABEL:-app.kubernetes.io/name=seaweed-vfs-rdma-node-workers}"
CLIENT_CONTAINER="${CLIENT_CONTAINER:-shell}"
WORKER_CONTAINER="${WORKER_CONTAINER:-swvfs-rdma-daemon}"
VOLUME_POD="${VOLUME_POD:-seaweedfs-volume-r7615-0}"
VOLUME_CONTAINER="${VOLUME_CONTAINER:-rdma-engine}"
WORKER_ENGINE_CONTAINER="${WORKER_ENGINE_CONTAINER:-rdma-engine}"
ENGINE_METRICS_URL="${ENGINE_METRICS_URL:-http://127.0.0.1:18085/metrics}"
WORKER_CONTROL_METRICS_URL="${WORKER_CONTROL_METRICS_URL:-http://127.0.0.1:18084/metrics}"
CLIENT_MOUNT="${CLIENT_MOUNT:-/mnt/seaweedvfs}"
WORKER_MOUNT="${WORKER_MOUNT:-/var/lib/seaweedfs-vfs/mnt}"
WRITER_NODE="${WRITER_NODE:-hnode1}"
READER_NODES="${READER_NODES:-hnode2 hnode3}"
FAILOVER_NODE="${FAILOVER_NODE:-hnode2}"
SMOKE_SIZE_MB="${SMOKE_SIZE_MB:-64}"
FIO_SIZE="${FIO_SIZE:-256M}"
RUN_FIO="${RUN_FIO:-true}"
RUN_WRITE_BATCH_PROBE="${RUN_WRITE_BATCH_PROBE:-true}"
WRITE_BATCH_PROBE_SIZE="${WRITE_BATCH_PROBE_SIZE:-64M}"
RUN_PJDFSTEST="${RUN_PJDFSTEST:-true}"
RUN_FAILOVER="${RUN_FAILOVER:-true}"
RUN_METRICS="${RUN_METRICS:-true}"
ASSERT_KERNEL_READ_COUNTERS="${ASSERT_KERNEL_READ_COUNTERS:-true}"
ASSERT_DIRECT_READ_NO_FALLBACK="${ASSERT_DIRECT_READ_NO_FALLBACK:-true}"
ASSERT_NATIVE_RDMA_PEERS="${ASSERT_NATIVE_RDMA_PEERS:-true}"
ASSERT_KERNEL_RDMA_PIPELINED_WRS="${ASSERT_KERNEL_RDMA_PIPELINED_WRS:-false}"
RUN_VOLUME_LOG_GATE="${RUN_VOLUME_LOG_GATE:-false}"
RUN_LOCAL_RDMA_GATE="${RUN_LOCAL_RDMA_GATE:-true}"
LOCAL_RDMA_GATE_REQUIRE_CONNECTED="${LOCAL_RDMA_GATE_REQUIRE_CONNECTED:-false}"
LOCAL_RDMA_GATE_REQUIRE_PAGECACHE_WRITEBACK="${LOCAL_RDMA_GATE_REQUIRE_PAGECACHE_WRITEBACK:-false}"
PJDFSTEST_TESTS="${PJDFSTEST_TESTS:-tests/open/25.t tests/unlink/14.t tests/open/26.t tests/mkdir/00.t tests/rename/20.t tests/rename/24.t}"

if command -v kubectl >/dev/null 2>&1; then
  KUBECTL=(kubectl)
elif command -v microk8s >/dev/null 2>&1; then
  KUBECTL=(microk8s kubectl)
else
  echo "ERROR: kubectl not found" >&2
  exit 1
fi

kctl() { "${KUBECTL[@]}" "$@"; }
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
is_truthy() {
  case "${1:-}" in
    Y|y|1|true|TRUE|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

is_uint() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

pod_by_node() {
  local label=$1
  local node=$2
  kctl -n "${NS}" get pod \
    -l "${label}" \
    --field-selector "spec.nodeName=${node}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

require_pod() {
  local label=$1
  local node=$2
  local pod
  pod="$(pod_by_node "${label}" "${node}")"
  [ -n "${pod}" ] || die "no pod for label '${label}' on node '${node}'"
  printf '%s\n' "${pod}"
}

client_pod() { require_pod "${CLIENT_LABEL}" "$1"; }
worker_pod() { require_pod "${WORKER_LABEL}" "$1"; }

exec_client() {
  local pod=$1
  shift
  kctl -n "${NS}" exec "${pod}" -c "${CLIENT_CONTAINER}" -- bash -lc "$*"
}

exec_worker() {
  local pod=$1
  shift
  kctl -n "${NS}" exec "${pod}" -c "${WORKER_CONTAINER}" -- sh -lc "$*"
}

fetch_container_metrics() {
  local namespace=$1
  local pod=$2
  local container=$3
  local url=$4
  kctl -n "${namespace}" exec "${pod}" -c "${container}" -- sh -lc "curl -fsS '${url}'"
}

fetch_volume_engine_metrics() {
  fetch_container_metrics "${SEAWEED_NS}" "${VOLUME_POD}" "${VOLUME_CONTAINER}" "${ENGINE_METRICS_URL}"
}

fetch_worker_engine_metrics() {
  local pod=$1
  fetch_container_metrics "${NS}" "${pod}" "${WORKER_ENGINE_CONTAINER}" "${ENGINE_METRICS_URL}"
}

fetch_worker_control_metrics() {
  local pod=$1
  fetch_container_metrics "${NS}" "${pod}" "${WORKER_CONTAINER}" "${WORKER_CONTROL_METRICS_URL}"
}

fetch_worker_control_path() {
  local pod=$1
  local path=$2
  kctl -n "${NS}" exec "${pod}" -c "${WORKER_CONTAINER}" -- sh -lc "wget -qO- 'http://127.0.0.1:18084${path}'"
}

fetch_volume_native_path() {
  local path=$1
  kctl -n "${SEAWEED_NS}" exec "${VOLUME_POD}" -c volume -- sh -lc "wget -qO- \"http://\${POD_IP}:8444${path}\""
}

metric_counter() {
  local payload=$1
  local name=$2
  METRICS_PAYLOAD="${payload}" python3 - "${name}" <<'PY'
import json
import os
import sys

name = sys.argv[1]
try:
    doc = json.loads(os.environ.get("METRICS_PAYLOAD", "{}"))
except Exception:
    print(0)
    raise SystemExit

for counter in doc.get("counters", []):
    if counter.get("name") == name:
        print(int(counter.get("value", 0)))
        break
else:
    print(0)
PY
}

wait_for_pod_ready() {
  local pod=$1
  kctl -n "${NS}" wait --for=condition=Ready "pod/${pod}" --timeout=180s >/dev/null
}

assert_client_mount() {
  local pod=$1
  exec_client "${pod}" "grep -q ' ${CLIENT_MOUNT} ' /proc/mounts && grep ' ${CLIENT_MOUNT} ' /proc/mounts"
}

assert_worker_mount() {
  local pod=$1
  exec_worker "${pod}" "grep -q ' ${WORKER_MOUNT} ' /proc/mounts && grep ' ${WORKER_MOUNT} ' /proc/mounts"
}

ensure_fio() {
  local pod=$1
  exec_client "${pod}" '
    set -euo pipefail
    if [ ! -x /usr/bin/fio ]; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y --no-install-recommends fio ca-certificates coreutils
    fi
  '
}

assert_log_contains() {
  local haystack=$1
  local needle=$2
  local label=$3
  if ! grep -q "${needle}" <<<"${haystack}"; then
    echo "--- ${label} logs ---" >&2
    printf '%s\n' "${haystack}" >&2
    die "expected '${needle}' in ${label} logs"
  fi
}

assert_log_absent() {
  local haystack=$1
  local needle=$2
  local label=$3
  if grep -q "${needle}" <<<"${haystack}"; then
    echo "--- ${label} logs ---" >&2
    printf '%s\n' "${haystack}" >&2
    die "unexpected '${needle}' in ${label} logs"
  fi
}

worker_counter() {
  local pod=$1
  local name=$2
  exec_worker "${pod}" "cat '/sys/module/seaweedvfs/parameters/${name}' 2>/dev/null || printf 0"
}

require_worker_param_exists() {
  local pod=$1
  local name=$2
  exec_worker "${pod}" "test -e '/sys/module/seaweedvfs/parameters/${name}'" \
    || die "missing seaweedvfs module parameter/counter on ${pod}: ${name}"
}

require_worker_truthy_param() {
  local pod=$1
  local name=$2
  local value
  require_worker_param_exists "${pod}" "${name}"
  value="$(worker_counter "${pod}" "${name}")"
  is_truthy "${value}" || die "${name} is not enabled on ${pod}: ${value}"
  log "OK: ${pod} ${name}=${value}"
}

require_worker_uint_counter() {
  local pod=$1
  local name=$2
  local value
  require_worker_param_exists "${pod}" "${name}"
  value="$(worker_counter "${pod}" "${name}")"
  is_uint "${value}" || die "${name} is not a numeric counter on ${pod}: ${value}"
  log "OK: ${pod} ${name}=${value}"
}

endpoint_env_value() {
  local payload=$1
  local name=$2
  awk -F= -v key="${name}" '$1 == key { print $2; found = 1; exit } END { if (!found) exit 1 }' <<<"${payload}"
}

assert_worker_endpoint_env() {
  local pod=$1
  local endpoint_env=$2
  local abi
  local qpn
  local psn
  local flags
  local link_layer
  local lid
  local gid
  local port_state

  abi="$(endpoint_env_value "${endpoint_env}" SWVFS_ABI_VERSION || true)"
  qpn="$(endpoint_env_value "${endpoint_env}" SWVFS_QP_NUM || true)"
  psn="$(endpoint_env_value "${endpoint_env}" SWVFS_PSN || true)"
  flags="$(endpoint_env_value "${endpoint_env}" SWVFS_FLAGS || true)"
  link_layer="$(endpoint_env_value "${endpoint_env}" SWVFS_LINK_LAYER || true)"
  lid="$(endpoint_env_value "${endpoint_env}" SWVFS_LID || true)"
  gid="$(endpoint_env_value "${endpoint_env}" SWVFS_GID || true)"
  port_state="$(endpoint_env_value "${endpoint_env}" SWVFS_PORT_STATE || true)"

  [ "${abi}" = "1" ] || die "unexpected seaweedvfs RDMA ABI on ${pod}: ${abi:-unset}"
  is_uint "${qpn}" && [ "${qpn}" -ne 0 ] || die "RDMA QP is not allocated on ${pod}: ${qpn:-unset}"
  is_uint "${psn}" && [ "${psn}" -ne 0 ] || die "RDMA PSN is not allocated on ${pod}: ${psn:-unset}"
  is_uint "${flags}" || die "RDMA endpoint flags are not numeric on ${pod}: ${flags:-unset}"

  case "${link_layer}" in
    1)
      is_uint "${lid}" && [ "${lid}" -ne 0 ] || die "InfiniBand endpoint has no LID on ${pod}: ${lid:-unset}"
      ;;
    2)
      [ -n "${gid}" ] || die "RoCE endpoint has no GID on ${pod}"
      ;;
    *)
      log "WARN: ${pod} unknown RDMA link layer: ${link_layer:-unset}"
      ;;
  esac

  if [ "${port_state}" != "4" ]; then
    log "WARN: ${pod} RDMA port state is ${port_state:-unset}, expected 4 (ACTIVE)"
  fi

  if is_truthy "${LOCAL_RDMA_GATE_REQUIRE_CONNECTED}" && [ $((flags & 8)) -ne 8 ]; then
    die "RDMA QP is not connected on ${pod}; endpoint flags=${flags}"
  fi

  log "OK: ${pod} RDMA ABI=${abi} qpn=${qpn} psn=${psn} flags=${flags}"
}

run_worker_local_rdma_gate() {
  local pod=$1
  local endpoint_env
  local counter
  local script_env

  is_truthy "${RUN_LOCAL_RDMA_GATE}" || return 0

  log "Checking local SeaweedFS-over-RDMA gate on ${pod}"
  script_env="REQUIRE_CONNECTED='${LOCAL_RDMA_GATE_REQUIRE_CONNECTED}' REQUIRE_PAGECACHE_WRITEBACK='${LOCAL_RDMA_GATE_REQUIRE_PAGECACHE_WRITEBACK}'"
  if exec_worker "${pod}" "test -x /app/swvfs-rdma-local-gate.sh"; then
    exec_worker "${pod}" "${script_env} /app/swvfs-rdma-local-gate.sh"
    return 0
  fi
  if exec_worker "${pod}" "command -v swvfs-rdma-local-gate.sh >/dev/null 2>&1"; then
    exec_worker "${pod}" "${script_env} swvfs-rdma-local-gate.sh"
    return 0
  fi

  exec_worker "${pod}" "test -e /dev/seaweedvfs" || die "/dev/seaweedvfs is missing on ${pod}"
  exec_worker "${pod}" "test -d /sys/module/seaweedvfs/parameters" || die "seaweedvfs sysfs is missing on ${pod}"
  require_worker_truthy_param "${pod}" kernel_rdma
  require_worker_truthy_param "${pod}" kernel_rdma_direct_reads
  require_worker_truthy_param "${pod}" kernel_rdma_direct_writes
  if is_truthy "${LOCAL_RDMA_GATE_REQUIRE_PAGECACHE_WRITEBACK}"; then
    require_worker_truthy_param "${pod}" kernel_rdma_pagecache_writeback
  fi

  for counter in \
    kernel_rdma_remote_read_posts \
    kernel_rdma_remote_read_completions \
    kernel_rdma_remote_read_failures \
    kernel_rdma_remote_write_posts \
    kernel_rdma_remote_write_completions \
    kernel_rdma_remote_write_failures \
    kernel_rdma_direct_read_ops \
    kernel_read_rdma_folio_direct_bytes \
    kernel_rdma_direct_write_ops \
    kernel_rdma_direct_write_bytes \
    kernel_rdma_read_fallbacks \
    kernel_write_rdma_fallbacks; do
    require_worker_uint_counter "${pod}" "${counter}"
  done

  if exec_worker "${pod}" "command -v swvfs-rdma-ctl >/dev/null 2>&1"; then
    endpoint_env="$(exec_worker "${pod}" "swvfs-rdma-ctl info-env")"
    assert_worker_endpoint_env "${pod}" "${endpoint_env}"
  else
    log "WARN: swvfs-rdma-ctl is missing on ${pod}; skipped endpoint ioctl ABI check"
  fi
}

assert_counter_increased() {
  local label=$1
  local before=$2
  local after=$3
  if [ "${after}" -le "${before}" ]; then
    die "${label} did not increase: before=${before} after=${after}"
  fi
  log "OK: ${label} increased (${before} -> ${after})"
}

assert_counter_unchanged() {
  local label=$1
  local before=$2
  local after=$3
  if [ "${after}" -ne "${before}" ]; then
    die "${label} changed: before=${before} after=${after}"
  fi
  log "OK: ${label} unchanged (${after})"
}

assert_metric_increased() {
  local label=$1
  local before_payload=$2
  local after_payload=$3
  local counter=$4
  local before
  local after
  before="$(metric_counter "${before_payload}" "${counter}")"
  after="$(metric_counter "${after_payload}" "${counter}")"
  if [ "${after}" -le "${before}" ]; then
    die "${label} did not increase: before=${before} after=${after} counter=${counter}"
  fi
  log "OK: ${label} increased (${before} -> ${after})"
}

assert_metric_unchanged() {
  local label=$1
  local before_payload=$2
  local after_payload=$3
  local counter=$4
  local before
  local after
  before="$(metric_counter "${before_payload}" "${counter}")"
  after="$(metric_counter "${after_payload}" "${counter}")"
  if [ "${after}" -ne "${before}" ]; then
    die "${label} changed: before=${before} after=${after} counter=${counter}"
  fi
  log "OK: ${label} unchanged (${after})"
}

metric_delta() {
  local before_payload=$1
  local after_payload=$2
  local counter=$3
  local before
  local after
  before="$(metric_counter "${before_payload}" "${counter}")"
  after="$(metric_counter "${after_payload}" "${counter}")"
  printf '%s\n' "$((after - before))"
}

log_metric_average_size() {
  local label=$1
  local before_payload=$2
  local after_payload=$3
  local count_counter=$4
  local byte_counter=$5
  local count_delta
  local byte_delta
  count_delta="$(metric_delta "${before_payload}" "${after_payload}" "${count_counter}")"
  byte_delta="$(metric_delta "${before_payload}" "${after_payload}" "${byte_counter}")"
  if [ "${count_delta}" -gt 0 ]; then
    log "INFO: ${label}: desc_delta=${count_delta} byte_delta=${byte_delta} avg_desc_bytes=$((byte_delta / count_delta))"
  else
    log "INFO: ${label}: desc_delta=${count_delta} byte_delta=${byte_delta}"
  fi
}

assert_volume_native_ready() {
  local status_payload=$1
  local endpoint_payload=$2
  VOLUME_STATUS_PAYLOAD="${status_payload}" VOLUME_ENDPOINT_PAYLOAD="${endpoint_payload}" python3 - <<'PY'
import json
import os
import sys

try:
    status = json.loads(os.environ.get("VOLUME_STATUS_PAYLOAD", "{}"))
    endpoint = json.loads(os.environ.get("VOLUME_ENDPOINT_PAYLOAD", "{}"))
except Exception as exc:
    print(f"ERROR: failed to decode native RDMA endpoint JSON: {exc}", file=sys.stderr)
    sys.exit(1)

errors = []
if not status.get("read_exporter_configured"):
    errors.append("volume read exporter is not configured")
if not status.get("endpoint_configured"):
    errors.append("volume native endpoint is not configured")
if status.get("abi_version") != 1:
    errors.append(f"volume native ABI is {status.get('abi_version')}, want 1")

if endpoint.get("abi_version") != 1:
    errors.append(f"volume endpoint ABI is {endpoint.get('abi_version')}, want 1")
if not endpoint.get("kernel_enabled"):
    errors.append("volume endpoint kernel_enabled=false")
if not endpoint.get("endpoint_ready"):
    errors.append("volume endpoint endpoint_ready=false")
if int(endpoint.get("qp_num") or 0) == 0:
    errors.append("volume endpoint qp_num=0")
if int(endpoint.get("lid") or 0) == 0:
    errors.append("volume endpoint lid=0")
if int(endpoint.get("link_layer") or 0) not in (1, 2):
    errors.append(f"volume endpoint link_layer={endpoint.get('link_layer')}, want 1 or 2")

if errors:
    print("ERROR: native volume RDMA endpoint is not production-ready:", file=sys.stderr)
    for error in errors:
        print(f"  - {error}", file=sys.stderr)
    print(f"status={status}", file=sys.stderr)
    print(f"endpoint={endpoint}", file=sys.stderr)
    sys.exit(1)

print(
    "OK: native volume RDMA endpoint ready "
    f"device={endpoint.get('device')} lid={endpoint.get('lid')} "
    f"qpn={endpoint.get('qp_num')} link_layer={endpoint.get('link_layer')}"
)
PY
}

assert_native_peer_connected() {
  local label=$1
  local payload=$2
  NATIVE_PEERS_PAYLOAD="${payload}" python3 - "${label}" <<'PY'
import json
import os
import sys

label = sys.argv[1]
try:
    doc = json.loads(os.environ.get("NATIVE_PEERS_PAYLOAD", "{}"))
except Exception as exc:
    print(f"ERROR: {label} native peer JSON decode failed: {exc}", file=sys.stderr)
    sys.exit(1)

peers = doc.get("peers") or []
if not peers:
    print(f"ERROR: {label} has no cached native volume RDMA peers", file=sys.stderr)
    print(f"payload={doc}", file=sys.stderr)
    sys.exit(1)

ready = []
errors = []
for peer in peers:
    local = peer.get("local") or {}
    peer_errors = []
    if int(peer.get("volume_connection_id") or 0) == 0:
        peer_errors.append("volume_connection_id=0")
    if peer.get("error"):
        peer_errors.append(f"snapshot error={peer.get('error')}")
    if not peer.get("ready"):
        peer_errors.append("ready=false")
    if not peer.get("connected"):
        peer_errors.append("connected=false")
    if not local.get("kernel_enabled"):
        peer_errors.append("local.kernel_enabled=false")
    if not local.get("endpoint_ready"):
        peer_errors.append("local.endpoint_ready=false")
    if not local.get("qp_connected"):
        peer_errors.append("local.qp_connected=false")
    if int(local.get("qp_num") or 0) == 0:
        peer_errors.append("local.qp_num=0")
    if int(local.get("lid") or 0) == 0:
        peer_errors.append("local.lid=0")
    if int(local.get("link_layer") or 0) not in (1, 2):
        peer_errors.append(f"local.link_layer={local.get('link_layer')}")
    if peer_errors:
        errors.append({"peer": peer, "errors": peer_errors})
    else:
        ready.append(peer)

if not ready:
    print(f"ERROR: {label} has no connected native volume RDMA peer", file=sys.stderr)
    print(json.dumps(errors, indent=2, sort_keys=True), file=sys.stderr)
    sys.exit(1)

peer = ready[0]
local = peer.get("local") or {}
print(
    f"OK: {label} native volume RDMA peer connected "
    f"volume_connection_id={peer.get('volume_connection_id')} "
    f"device={local.get('device')} lid={local.get('lid')} qpn={local.get('qp_num')}"
)
PY
}

log "Resolving pods"
read -r -a reader_nodes <<<"${READER_NODES}"
writer_client="$(client_pod "${WRITER_NODE}")"
writer_worker="$(worker_pod "${WRITER_NODE}")"
failover_client="$(client_pod "${FAILOVER_NODE}")"

reader_clients=()
reader_workers=()
for node in "${reader_nodes[@]}"; do
  reader_clients+=("$(client_pod "${node}")")
  reader_workers+=("$(worker_pod "${node}")")
done

log "Checking mounts"
assert_client_mount "${writer_client}"
assert_worker_mount "${writer_worker}"
for pod in "${reader_clients[@]}"; do
  assert_client_mount "${pod}"
done
for pod in "${reader_workers[@]}"; do
  assert_worker_mount "${pod}"
done

run_worker_local_rdma_gate "${writer_worker}"
for pod in "${reader_workers[@]}"; do
  run_worker_local_rdma_gate "${pod}"
done

if [ "${ASSERT_NATIVE_RDMA_PEERS}" = "true" ]; then
  log "Checking native volume RDMA endpoint readiness"
  volume_native_status="$(fetch_volume_native_path /rdma/native/status)"
  volume_native_endpoint="$(fetch_volume_native_path /rdma/native/local)"
  assert_volume_native_ready "${volume_native_status}" "${volume_native_endpoint}"
fi

since_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
test_dir="${CLIENT_MOUNT}/rdma-prod-gate-$(date +%Y%m%d-%H%M%S)"
smoke_file="${test_dir}/payload.bin"
write_batch_file="${test_dir}/write-batch.bin"
fio_file="${test_dir}/fio.bin"
writer_write_ops_before="$(worker_counter "${writer_worker}" kernel_write_rdma_ops)"
writer_write_completions_before="$(worker_counter "${writer_worker}" kernel_rdma_remote_write_completions)"
writer_direct_write_ops_before="$(worker_counter "${writer_worker}" kernel_rdma_direct_write_ops)"
writer_direct_write_bytes_before="$(worker_counter "${writer_worker}" kernel_rdma_direct_write_bytes)"
writer_direct_write_fallbacks_before="$(worker_counter "${writer_worker}" kernel_rdma_direct_write_fallbacks)"
writer_direct_write_errors_before="$(worker_counter "${writer_worker}" kernel_rdma_direct_write_errors)"
writer_write_direct_before="$(worker_counter "${writer_worker}" kernel_write_rdma_direct_iter_bytes)"
writer_write_bounce_before="$(worker_counter "${writer_worker}" kernel_write_rdma_bounce_copy_bytes)"
writer_send_batches_before="$(worker_counter "${writer_worker}" kernel_rdma_send_batches)"
writer_send_batch_wrs_before="$(worker_counter "${writer_worker}" kernel_rdma_send_batch_wrs)"
writer_deferred_queued_before="$(worker_counter "${writer_worker}" kernel_write_rdma_deferred_queued)"
writer_deferred_flushed_before="$(worker_counter "${writer_worker}" kernel_write_rdma_deferred_flushed)"
writer_deferred_flushes_before="$(worker_counter "${writer_worker}" kernel_write_rdma_deferred_flushes)"
writer_deferred_errors_before="$(worker_counter "${writer_worker}" kernel_write_rdma_deferred_errors)"
writer_async_queued_before="$(worker_counter "${writer_worker}" kernel_write_rdma_async_queued)"
writer_async_flushed_before="$(worker_counter "${writer_worker}" kernel_write_rdma_async_flushed)"
writer_async_flushes_before="$(worker_counter "${writer_worker}" kernel_write_rdma_async_flushes)"
writer_async_errors_before="$(worker_counter "${writer_worker}" kernel_write_rdma_async_errors)"
writer_async_bytes_before="$(worker_counter "${writer_worker}" kernel_write_rdma_async_bytes)"
writer_async_backpressure_before="$(worker_counter "${writer_worker}" kernel_write_rdma_async_backpressure)"
writer_commit_batch_ops_before="$(worker_counter "${writer_worker}" kernel_write_rdma_commit_batch_ops)"
writer_commit_batch_entries_before="$(worker_counter "${writer_worker}" kernel_write_rdma_commit_batch_entries)"
writer_commit_batch_errors_before="$(worker_counter "${writer_worker}" kernel_write_rdma_commit_batch_errors)"
writer_write_prepare_batch_ops_before="$(worker_counter "${writer_worker}" kernel_rdma_write_prepare_batch_ops)"
writer_write_prepare_batch_descs_before="$(worker_counter "${writer_worker}" kernel_rdma_write_prepare_batch_descs)"
writer_write_prepare_batch_fallbacks_before="$(worker_counter "${writer_worker}" kernel_rdma_write_prepare_batch_fallbacks)"
writer_pagecache_writeback="$(worker_counter "${writer_worker}" kernel_rdma_pagecache_writeback)"
writer_pagecache_write_ops_before="$(worker_counter "${writer_worker}" kernel_write_rdma_pagecache_write_ops)"
writer_pagecache_write_bytes_before="$(worker_counter "${writer_worker}" kernel_write_rdma_pagecache_write_bytes)"
writer_pagecache_dirty_folios_before="$(worker_counter "${writer_worker}" kernel_write_rdma_pagecache_dirty_folios)"
writer_pagecache_writepages_ops_before="$(worker_counter "${writer_worker}" kernel_write_rdma_pagecache_writepages_ops)"
writer_pagecache_writeback_ops_before="$(worker_counter "${writer_worker}" kernel_write_rdma_pagecache_writeback_ops)"
writer_pagecache_writeback_bytes_before="$(worker_counter "${writer_worker}" kernel_write_rdma_pagecache_writeback_bytes)"
writer_pagecache_writeback_fallbacks_before="$(worker_counter "${writer_worker}" kernel_write_rdma_pagecache_writeback_fallbacks)"
writer_pagecache_writeback_errors_before="$(worker_counter "${writer_worker}" kernel_write_rdma_pagecache_writeback_errors)"
reader_read_desc_before="$(worker_counter "${reader_workers[0]}" kernel_read_rdma_desc_ops)"
reader_read_completions_before="$(worker_counter "${reader_workers[0]}" kernel_rdma_remote_read_completions)"
reader_read_direct_before="$(worker_counter "${reader_workers[0]}" kernel_read_rdma_folio_direct_bytes)"
reader_read_bounce_before="$(worker_counter "${reader_workers[0]}" kernel_read_rdma_bounce_copy_bytes)"
reader_read_batch_ops_before="$(worker_counter "${reader_workers[0]}" kernel_rdma_read_prepare_batch_ops)"
reader_read_batch_descs_before="$(worker_counter "${reader_workers[0]}" kernel_rdma_read_prepare_batch_descs)"
reader_read_batch_fallbacks_before="$(worker_counter "${reader_workers[0]}" kernel_rdma_read_prepare_batch_fallbacks)"
reader_send_batches_before="$(worker_counter "${reader_workers[0]}" kernel_rdma_send_batches)"
reader_send_batch_wrs_before="$(worker_counter "${reader_workers[0]}" kernel_rdma_send_batch_wrs)"
reader_direct_ops_before="$(worker_counter "${reader_workers[0]}" kernel_rdma_direct_read_ops)"
reader_direct_bytes_before="$(worker_counter "${reader_workers[0]}" kernel_rdma_direct_read_bytes)"
reader_direct_fallbacks_before="$(worker_counter "${reader_workers[0]}" kernel_rdma_direct_read_fallbacks)"
reader_direct_errors_before="$(worker_counter "${reader_workers[0]}" kernel_rdma_direct_read_errors)"

if [ "${RUN_METRICS}" = "true" ]; then
  log "Capturing RDMA metrics baseline"
  writer_metrics_before="$(fetch_worker_control_metrics "${writer_worker}")"
  reader_metrics_before="$(fetch_worker_control_metrics "${reader_workers[0]}")"
  fetch_volume_engine_metrics >/dev/null || true
  fetch_worker_engine_metrics "${writer_worker}" >/dev/null || true
  fetch_worker_engine_metrics "${reader_workers[0]}" >/dev/null || true
fi

log "Smoke write on ${WRITER_NODE}: ${SMOKE_SIZE_MB}MiB"
writer_sha="$(
  exec_client "${writer_client}" "
    set -euo pipefail
    mkdir -p '${test_dir}'
    dd if=/dev/urandom of='${smoke_file}' bs=1M count='${SMOKE_SIZE_MB}' status=none
    sync '${smoke_file}'
    sha256sum '${smoke_file}'
  " | awk '{print $1}'
)"
[ -n "${writer_sha}" ] || die "failed to compute writer checksum"
log "Writer checksum: ${writer_sha}"

for i in "${!reader_clients[@]}"; do
  node="${reader_nodes[$i]}"
  pod="${reader_clients[$i]}"
  log "Smoke read on ${node}"
  reader_sha="$(exec_client "${pod}" "sha256sum '${smoke_file}'" | awk '{print $1}')"
  [ "${reader_sha}" = "${writer_sha}" ] || die "checksum mismatch on ${node}: ${reader_sha} != ${writer_sha}"
done

if [ "${RUN_WRITE_BATCH_PROBE}" = "true" ]; then
  log "Write batch probe on ${WRITER_NODE}: ${WRITE_BATCH_PROBE_SIZE}"
  exec_client "${writer_client}" "
    set -euo pipefail
    dd if=/dev/zero of='${write_batch_file}' bs='${WRITE_BATCH_PROBE_SIZE}' count=1 status=none
    sync '${write_batch_file}'
  "
fi

if [ "${RUN_FIO}" = "true" ]; then
  log "Running fio (${FIO_SIZE})"
  ensure_fio "${writer_client}"
  ensure_fio "${reader_clients[0]}"
  exec_client "${writer_client}" "
    set -euo pipefail
    /usr/bin/fio --name=rdma-seqwrite --filename='${fio_file}' --size='${FIO_SIZE}' \
      --rw=write --bs=8M --ioengine=sync --direct=0 --iodepth=1 --numjobs=1 \
      --group_reporting --fsync_on_close=1
  "
  exec_client "${reader_clients[0]}" "
    set -euo pipefail
    /usr/bin/fio --name=rdma-seqread --filename='${fio_file}' --size='${FIO_SIZE}' \
      --rw=read --bs=8M --ioengine=sync --direct=0 --iodepth=1 --numjobs=1 \
      --group_reporting
  "
fi

assert_counter_increased "kernel_write_rdma_ops on ${writer_worker}" "${writer_write_ops_before}" "$(worker_counter "${writer_worker}" kernel_write_rdma_ops)"
assert_counter_increased "kernel_rdma_remote_write_completions on ${writer_worker}" "${writer_write_completions_before}" "$(worker_counter "${writer_worker}" kernel_rdma_remote_write_completions)"
assert_counter_increased "kernel_rdma_direct_write_ops on ${writer_worker}" "${writer_direct_write_ops_before}" "$(worker_counter "${writer_worker}" kernel_rdma_direct_write_ops)"
assert_counter_increased "kernel_rdma_direct_write_bytes on ${writer_worker}" "${writer_direct_write_bytes_before}" "$(worker_counter "${writer_worker}" kernel_rdma_direct_write_bytes)"
assert_counter_unchanged "kernel_rdma_direct_write_fallbacks on ${writer_worker}" "${writer_direct_write_fallbacks_before}" "$(worker_counter "${writer_worker}" kernel_rdma_direct_write_fallbacks)"
assert_counter_unchanged "kernel_rdma_direct_write_errors on ${writer_worker}" "${writer_direct_write_errors_before}" "$(worker_counter "${writer_worker}" kernel_rdma_direct_write_errors)"
assert_counter_increased "kernel_rdma_send_batches on ${writer_worker}" "${writer_send_batches_before}" "$(worker_counter "${writer_worker}" kernel_rdma_send_batches)"
assert_counter_increased "kernel_rdma_send_batch_wrs on ${writer_worker}" "${writer_send_batch_wrs_before}" "$(worker_counter "${writer_worker}" kernel_rdma_send_batch_wrs)"
writer_max_batch_wrs="$(worker_counter "${writer_worker}" kernel_rdma_send_max_batch_wrs)"
if [ "${ASSERT_KERNEL_RDMA_PIPELINED_WRS}" = "true" ] && [ "${writer_max_batch_wrs}" -le 1 ]; then
  die "kernel_rdma_send_max_batch_wrs on ${writer_worker} did not prove pipelined WR posting: ${writer_max_batch_wrs}"
fi
log "kernel_rdma_send_max_batch_wrs on ${writer_worker}=${writer_max_batch_wrs}"
assert_counter_unchanged "kernel_write_rdma_bounce_copy_bytes on ${writer_worker}" "${writer_write_bounce_before}" "$(worker_counter "${writer_worker}" kernel_write_rdma_bounce_copy_bytes)"
if is_truthy "${writer_pagecache_writeback}"; then
  log "Checking page-cache RDMA writeback counters on ${writer_worker}"
  assert_counter_increased "kernel_write_rdma_pagecache_write_ops on ${writer_worker}" "${writer_pagecache_write_ops_before}" "$(worker_counter "${writer_worker}" kernel_write_rdma_pagecache_write_ops)"
  assert_counter_increased "kernel_write_rdma_pagecache_write_bytes on ${writer_worker}" "${writer_pagecache_write_bytes_before}" "$(worker_counter "${writer_worker}" kernel_write_rdma_pagecache_write_bytes)"
  assert_counter_increased "kernel_write_rdma_pagecache_dirty_folios on ${writer_worker}" "${writer_pagecache_dirty_folios_before}" "$(worker_counter "${writer_worker}" kernel_write_rdma_pagecache_dirty_folios)"
  assert_counter_increased "kernel_write_rdma_pagecache_writepages_ops on ${writer_worker}" "${writer_pagecache_writepages_ops_before}" "$(worker_counter "${writer_worker}" kernel_write_rdma_pagecache_writepages_ops)"
  assert_counter_increased "kernel_write_rdma_pagecache_writeback_ops on ${writer_worker}" "${writer_pagecache_writeback_ops_before}" "$(worker_counter "${writer_worker}" kernel_write_rdma_pagecache_writeback_ops)"
  assert_counter_increased "kernel_write_rdma_pagecache_writeback_bytes on ${writer_worker}" "${writer_pagecache_writeback_bytes_before}" "$(worker_counter "${writer_worker}" kernel_write_rdma_pagecache_writeback_bytes)"
  assert_counter_unchanged "kernel_write_rdma_pagecache_writeback_fallbacks on ${writer_worker}" "${writer_pagecache_writeback_fallbacks_before}" "$(worker_counter "${writer_worker}" kernel_write_rdma_pagecache_writeback_fallbacks)"
  assert_counter_unchanged "kernel_write_rdma_pagecache_writeback_errors on ${writer_worker}" "${writer_pagecache_writeback_errors_before}" "$(worker_counter "${writer_worker}" kernel_write_rdma_pagecache_writeback_errors)"
  assert_counter_unchanged "kernel_write_rdma_direct_iter_bytes on ${writer_worker}" "${writer_write_direct_before}" "$(worker_counter "${writer_worker}" kernel_write_rdma_direct_iter_bytes)"
  assert_counter_unchanged "kernel_write_rdma_deferred_errors on ${writer_worker}" "${writer_deferred_errors_before}" "$(worker_counter "${writer_worker}" kernel_write_rdma_deferred_errors)"
  assert_counter_unchanged "kernel_write_rdma_async_errors on ${writer_worker}" "${writer_async_errors_before}" "$(worker_counter "${writer_worker}" kernel_write_rdma_async_errors)"
  assert_counter_unchanged "kernel_write_rdma_commit_batch_errors on ${writer_worker}" "${writer_commit_batch_errors_before}" "$(worker_counter "${writer_worker}" kernel_write_rdma_commit_batch_errors)"
  log "page-cache mode uses writepages RDMA batches; legacy async queue counters are informational"
else
  assert_counter_increased "kernel_write_rdma_direct_iter_bytes on ${writer_worker}" "${writer_write_direct_before}" "$(worker_counter "${writer_worker}" kernel_write_rdma_direct_iter_bytes)"
  assert_counter_increased "kernel_write_rdma_deferred_queued on ${writer_worker}" "${writer_deferred_queued_before}" "$(worker_counter "${writer_worker}" kernel_write_rdma_deferred_queued)"
  assert_counter_increased "kernel_write_rdma_deferred_flushed on ${writer_worker}" "${writer_deferred_flushed_before}" "$(worker_counter "${writer_worker}" kernel_write_rdma_deferred_flushed)"
  assert_counter_increased "kernel_write_rdma_deferred_flushes on ${writer_worker}" "${writer_deferred_flushes_before}" "$(worker_counter "${writer_worker}" kernel_write_rdma_deferred_flushes)"
  assert_counter_unchanged "kernel_write_rdma_deferred_errors on ${writer_worker}" "${writer_deferred_errors_before}" "$(worker_counter "${writer_worker}" kernel_write_rdma_deferred_errors)"
  assert_counter_increased "kernel_write_rdma_async_queued on ${writer_worker}" "${writer_async_queued_before}" "$(worker_counter "${writer_worker}" kernel_write_rdma_async_queued)"
  assert_counter_increased "kernel_write_rdma_async_flushed on ${writer_worker}" "${writer_async_flushed_before}" "$(worker_counter "${writer_worker}" kernel_write_rdma_async_flushed)"
  assert_counter_increased "kernel_write_rdma_async_flushes on ${writer_worker}" "${writer_async_flushes_before}" "$(worker_counter "${writer_worker}" kernel_write_rdma_async_flushes)"
  assert_counter_increased "kernel_write_rdma_async_bytes on ${writer_worker}" "${writer_async_bytes_before}" "$(worker_counter "${writer_worker}" kernel_write_rdma_async_bytes)"
  assert_counter_unchanged "kernel_write_rdma_async_errors on ${writer_worker}" "${writer_async_errors_before}" "$(worker_counter "${writer_worker}" kernel_write_rdma_async_errors)"
  log "kernel_write_rdma_async_backpressure on ${writer_worker}: ${writer_async_backpressure_before} -> $(worker_counter "${writer_worker}" kernel_write_rdma_async_backpressure)"
  assert_counter_increased "kernel_write_rdma_commit_batch_ops on ${writer_worker}" "${writer_commit_batch_ops_before}" "$(worker_counter "${writer_worker}" kernel_write_rdma_commit_batch_ops)"
  assert_counter_increased "kernel_write_rdma_commit_batch_entries on ${writer_worker}" "${writer_commit_batch_entries_before}" "$(worker_counter "${writer_worker}" kernel_write_rdma_commit_batch_entries)"
  assert_counter_unchanged "kernel_write_rdma_commit_batch_errors on ${writer_worker}" "${writer_commit_batch_errors_before}" "$(worker_counter "${writer_worker}" kernel_write_rdma_commit_batch_errors)"
  if [ "${RUN_WRITE_BATCH_PROBE}" = "true" ]; then
    assert_counter_increased "kernel_rdma_write_prepare_batch_ops on ${writer_worker}" "${writer_write_prepare_batch_ops_before}" "$(worker_counter "${writer_worker}" kernel_rdma_write_prepare_batch_ops)"
    assert_counter_increased "kernel_rdma_write_prepare_batch_descs on ${writer_worker}" "${writer_write_prepare_batch_descs_before}" "$(worker_counter "${writer_worker}" kernel_rdma_write_prepare_batch_descs)"
    assert_counter_unchanged "kernel_rdma_write_prepare_batch_fallbacks on ${writer_worker}" "${writer_write_prepare_batch_fallbacks_before}" "$(worker_counter "${writer_worker}" kernel_rdma_write_prepare_batch_fallbacks)"
  fi
fi
if [ "${ASSERT_KERNEL_READ_COUNTERS}" = "true" ]; then
  assert_counter_increased "kernel_rdma_direct_read_ops on ${reader_workers[0]}" "${reader_direct_ops_before}" "$(worker_counter "${reader_workers[0]}" kernel_rdma_direct_read_ops)"
  assert_counter_increased "kernel_rdma_direct_read_bytes on ${reader_workers[0]}" "${reader_direct_bytes_before}" "$(worker_counter "${reader_workers[0]}" kernel_rdma_direct_read_bytes)"
  assert_counter_increased "kernel_read_rdma_desc_ops on ${reader_workers[0]}" "${reader_read_desc_before}" "$(worker_counter "${reader_workers[0]}" kernel_read_rdma_desc_ops)"
  assert_counter_increased "kernel_rdma_remote_read_completions on ${reader_workers[0]}" "${reader_read_completions_before}" "$(worker_counter "${reader_workers[0]}" kernel_rdma_remote_read_completions)"
  assert_counter_increased "kernel_read_rdma_folio_direct_bytes on ${reader_workers[0]}" "${reader_read_direct_before}" "$(worker_counter "${reader_workers[0]}" kernel_read_rdma_folio_direct_bytes)"
  assert_counter_unchanged "kernel_read_rdma_bounce_copy_bytes on ${reader_workers[0]}" "${reader_read_bounce_before}" "$(worker_counter "${reader_workers[0]}" kernel_read_rdma_bounce_copy_bytes)"
  assert_counter_increased "kernel_rdma_read_prepare_batch_ops on ${reader_workers[0]}" "${reader_read_batch_ops_before}" "$(worker_counter "${reader_workers[0]}" kernel_rdma_read_prepare_batch_ops)"
  assert_counter_increased "kernel_rdma_read_prepare_batch_descs on ${reader_workers[0]}" "${reader_read_batch_descs_before}" "$(worker_counter "${reader_workers[0]}" kernel_rdma_read_prepare_batch_descs)"
  assert_counter_unchanged "kernel_rdma_read_prepare_batch_fallbacks on ${reader_workers[0]}" "${reader_read_batch_fallbacks_before}" "$(worker_counter "${reader_workers[0]}" kernel_rdma_read_prepare_batch_fallbacks)"
  assert_counter_increased "kernel_rdma_send_batches on ${reader_workers[0]}" "${reader_send_batches_before}" "$(worker_counter "${reader_workers[0]}" kernel_rdma_send_batches)"
  assert_counter_increased "kernel_rdma_send_batch_wrs on ${reader_workers[0]}" "${reader_send_batch_wrs_before}" "$(worker_counter "${reader_workers[0]}" kernel_rdma_send_batch_wrs)"
  reader_max_batch_wrs="$(worker_counter "${reader_workers[0]}" kernel_rdma_send_max_batch_wrs)"
  if [ "${ASSERT_KERNEL_RDMA_PIPELINED_WRS}" = "true" ] && [ "${reader_max_batch_wrs}" -le 1 ]; then
    die "kernel_rdma_send_max_batch_wrs on ${reader_workers[0]} did not prove pipelined WR posting: ${reader_max_batch_wrs}"
  fi
  log "kernel_rdma_send_max_batch_wrs on ${reader_workers[0]}=${reader_max_batch_wrs}"
  if [ "${ASSERT_DIRECT_READ_NO_FALLBACK}" = "true" ]; then
    assert_counter_unchanged "kernel_rdma_direct_read_fallbacks on ${reader_workers[0]}" "${reader_direct_fallbacks_before}" "$(worker_counter "${reader_workers[0]}" kernel_rdma_direct_read_fallbacks)"
    assert_counter_unchanged "kernel_rdma_direct_read_errors on ${reader_workers[0]}" "${reader_direct_errors_before}" "$(worker_counter "${reader_workers[0]}" kernel_rdma_direct_read_errors)"
  else
    log "kernel_rdma_direct_read_fallbacks on ${reader_workers[0]}: ${reader_direct_fallbacks_before} -> $(worker_counter "${reader_workers[0]}" kernel_rdma_direct_read_fallbacks)"
    log "kernel_rdma_direct_read_errors on ${reader_workers[0]}: ${reader_direct_errors_before} -> $(worker_counter "${reader_workers[0]}" kernel_rdma_direct_read_errors)"
  fi
else
  log "Skipping kernel read sysfs counters; RDMA read-v2 is gated by daemon and volume-engine metrics"
fi

if [ "${RUN_METRICS}" = "true" ]; then
  log "Checking RDMA path metrics"
  writer_metrics_after="$(fetch_worker_control_metrics "${writer_worker}")"
  reader_metrics_after="$(fetch_worker_control_metrics "${reader_workers[0]}")"
  assert_metric_increased "${writer_worker}/${WORKER_CONTAINER} native volume write desc" "${writer_metrics_before}" "${writer_metrics_after}" volume_native_rdma_write_desc_success
  if is_truthy "${writer_pagecache_writeback}"; then
    assert_metric_increased "${writer_worker}/${WORKER_CONTAINER} native volume write commit" "${writer_metrics_before}" "${writer_metrics_after}" volume_native_rdma_write_commit_success
    assert_metric_increased "${writer_worker}/${WORKER_CONTAINER} native volume write bytes" "${writer_metrics_before}" "${writer_metrics_after}" volume_native_rdma_write_commit_bytes
    assert_metric_increased "${writer_worker}/${WORKER_CONTAINER} handler_write_rdma_commit_requests" "${writer_metrics_before}" "${writer_metrics_after}" handler_write_rdma_commit_requests
  else
    assert_metric_increased "${writer_worker}/${WORKER_CONTAINER} native volume write commit batch" "${writer_metrics_before}" "${writer_metrics_after}" volume_native_rdma_write_commit_batch_success
    assert_metric_increased "${writer_worker}/${WORKER_CONTAINER} native volume write commit batch entries" "${writer_metrics_before}" "${writer_metrics_after}" volume_native_rdma_write_commit_batch_entry_success
    assert_metric_increased "${writer_worker}/${WORKER_CONTAINER} native volume write bytes" "${writer_metrics_before}" "${writer_metrics_after}" volume_native_rdma_write_commit_batch_bytes
    assert_metric_increased "${writer_worker}/${WORKER_CONTAINER} handler_write_rdma_commit_batch_ops" "${writer_metrics_before}" "${writer_metrics_after}" handler_write_rdma_commit_batch_ops
  fi
  if [ "${RUN_WRITE_BATCH_PROBE}" = "true" ] && ! is_truthy "${writer_pagecache_writeback}"; then
    assert_metric_increased "${writer_worker}/${WORKER_CONTAINER} native volume write desc batch" "${writer_metrics_before}" "${writer_metrics_after}" volume_native_rdma_write_desc_batch_success
    assert_metric_increased "${writer_worker}/${WORKER_CONTAINER} native volume write desc batch entries" "${writer_metrics_before}" "${writer_metrics_after}" volume_native_rdma_write_desc_batch_entries
    assert_metric_increased "${writer_worker}/${WORKER_CONTAINER} handler_write_rdma_prepare_batch_ops" "${writer_metrics_before}" "${writer_metrics_after}" handler_write_rdma_prepare_batch_ops
    assert_metric_increased "${writer_worker}/${WORKER_CONTAINER} handler_write_rdma_prepare_batch_replies" "${writer_metrics_before}" "${writer_metrics_after}" handler_write_rdma_prepare_batch_replies
    assert_metric_increased "${writer_worker}/${WORKER_CONTAINER} handler_write_rdma_prepare_batch_descs" "${writer_metrics_before}" "${writer_metrics_after}" handler_write_rdma_prepare_batch_descs
  fi
  assert_metric_increased "${reader_workers[0]}/${WORKER_CONTAINER} native volume read desc" "${reader_metrics_before}" "${reader_metrics_after}" volume_native_rdma_read_desc_success
  assert_metric_increased "${reader_workers[0]}/${WORKER_CONTAINER} native volume read bytes" "${reader_metrics_before}" "${reader_metrics_after}" volume_native_rdma_read_desc_bytes
  assert_metric_increased "${reader_workers[0]}/${WORKER_CONTAINER} handler_read_rdma_prepare_batch_replies" "${reader_metrics_before}" "${reader_metrics_after}" handler_read_rdma_prepare_batch_replies
  assert_metric_increased "${reader_workers[0]}/${WORKER_CONTAINER} handler_read_rdma_prepare_batch_descs" "${reader_metrics_before}" "${reader_metrics_after}" handler_read_rdma_prepare_batch_descs
  assert_metric_increased "${reader_workers[0]}/${WORKER_CONTAINER} handler_read_rdma_release_replies" "${reader_metrics_before}" "${reader_metrics_after}" handler_read_rdma_release_replies
  log_metric_average_size "${writer_worker}/${WORKER_CONTAINER} native volume write descriptors" "${writer_metrics_before}" "${writer_metrics_after}" volume_native_rdma_write_desc_success volume_native_rdma_write_desc_bytes
  log_metric_average_size "${reader_workers[0]}/${WORKER_CONTAINER} native volume read descriptors" "${reader_metrics_before}" "${reader_metrics_after}" volume_native_rdma_read_desc_success volume_native_rdma_read_desc_bytes
  assert_metric_unchanged "${writer_worker}/${WORKER_CONTAINER} native volume write desc errors" "${writer_metrics_before}" "${writer_metrics_after}" volume_native_rdma_write_desc_post_errors
  assert_metric_unchanged "${writer_worker}/${WORKER_CONTAINER} native volume write commit errors" "${writer_metrics_before}" "${writer_metrics_after}" volume_native_rdma_write_commit_errors
  assert_metric_unchanged "${writer_worker}/${WORKER_CONTAINER} native volume write commit batch errors" "${writer_metrics_before}" "${writer_metrics_after}" volume_native_rdma_write_commit_batch_errors
  assert_metric_unchanged "${writer_worker}/${WORKER_CONTAINER} native volume write commit batch post errors" "${writer_metrics_before}" "${writer_metrics_after}" volume_native_rdma_write_commit_batch_post_errors
  assert_metric_unchanged "${writer_worker}/${WORKER_CONTAINER} native volume write commit batch entry errors" "${writer_metrics_before}" "${writer_metrics_after}" volume_native_rdma_write_commit_batch_entry_errors
  assert_metric_unchanged "${writer_worker}/${WORKER_CONTAINER} native volume write peer errors" "${writer_metrics_before}" "${writer_metrics_after}" volume_native_rdma_write_peer_connect_errors
  assert_metric_unchanged "${reader_workers[0]}/${WORKER_CONTAINER} native volume read errors" "${reader_metrics_before}" "${reader_metrics_after}" volume_native_rdma_read_desc_errors
  assert_metric_unchanged "${reader_workers[0]}/${WORKER_CONTAINER} native volume read peer errors" "${reader_metrics_before}" "${reader_metrics_after}" volume_native_rdma_peer_connect_errors
fi

if [ "${ASSERT_NATIVE_RDMA_PEERS}" = "true" ]; then
  log "Checking connected native volume RDMA peers"
  assert_native_peer_connected "${writer_worker}/${WORKER_CONTAINER}" "$(fetch_worker_control_path "${writer_worker}" /rdma/native-peers)"
  assert_native_peer_connected "${reader_workers[0]}/${WORKER_CONTAINER}" "$(fetch_worker_control_path "${reader_workers[0]}" /rdma/native-peers)"
fi

log "Checking RDMA daemon logs"
for pod in "${writer_worker}" "${reader_workers[@]}"; do
  logs="$(kctl -n "${NS}" logs "${pod}" -c "${WORKER_CONTAINER}" --since-time="${since_time}" || true)"
  assert_log_absent "${logs}" "native volume RDMA write peer handshake failed" "${pod}"
  assert_log_absent "${logs}" "native volume RDMA read peer handshake failed" "${pod}"
done

if [ "${RUN_VOLUME_LOG_GATE}" = "true" ]; then
  volume_logs="$(kctl -n "${SEAWEED_NS}" logs "${VOLUME_POD}" -c "${VOLUME_CONTAINER}" --since-time="${since_time}" || true)"
  assert_log_absent "${volume_logs}" "direct volume gRPC write failed" "${VOLUME_POD}/${VOLUME_CONTAINER}"
  assert_log_absent "${volume_logs}" "volume ReadNeedleRange gRPC failed" "${VOLUME_POD}/${VOLUME_CONTAINER}"
  assert_log_absent "${volume_logs}" "local Rust volume read failed" "${VOLUME_POD}/${VOLUME_CONTAINER}"
  assert_log_contains "${volume_logs}" "RDMA GET from peer completed successfully" "${VOLUME_POD}/${VOLUME_CONTAINER}"
  assert_log_contains "${volume_logs}" "RDMA PUT to peer completed successfully" "${VOLUME_POD}/${VOLUME_CONTAINER}"
fi

if [ "${RUN_PJDFSTEST}" = "true" ]; then
  log "Running pjdfstest core gate"
  POD="${writer_client}" \
    MOUNT_DIR="${CLIENT_MOUNT}" \
    PJDFSTEST_TESTS="${PJDFSTEST_TESTS}" \
    "${SCRIPT_DIR}/run-pjdfstest-vfs.sh"
fi

if [ "${RUN_FAILOVER}" = "true" ]; then
  log "Restarting RDMA worker on ${FAILOVER_NODE}"
  old_worker="$(worker_pod "${FAILOVER_NODE}")"
  kctl -n "${NS}" delete pod "${old_worker}" --wait=true
  kctl -n "${NS}" rollout status daemonset/seaweed-vfs-rdma-node-workers --timeout=300s
  new_worker="$(worker_pod "${FAILOVER_NODE}")"
  wait_for_pod_ready "${new_worker}"
  assert_worker_mount "${new_worker}"
  failover_sha="$(exec_client "${failover_client}" "sha256sum '${smoke_file}'" | awk '{print $1}')"
  [ "${failover_sha}" = "${writer_sha}" ] || die "checksum mismatch after failover: ${failover_sha} != ${writer_sha}"
fi

log "Production gate passed"
