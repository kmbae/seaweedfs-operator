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
RUN_PJDFSTEST="${RUN_PJDFSTEST:-true}"
RUN_FAILOVER="${RUN_FAILOVER:-true}"
RUN_METRICS="${RUN_METRICS:-true}"
ASSERT_KERNEL_READ_COUNTERS="${ASSERT_KERNEL_READ_COUNTERS:-false}"
ASSERT_DIRECT_READ_NO_FALLBACK="${ASSERT_DIRECT_READ_NO_FALLBACK:-false}"
RUN_VOLUME_LOG_GATE="${RUN_VOLUME_LOG_GATE:-false}"
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

since_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
test_dir="${CLIENT_MOUNT}/rdma-prod-gate-$(date +%Y%m%d-%H%M%S)"
smoke_file="${test_dir}/payload.bin"
fio_file="${test_dir}/fio.bin"
writer_write_ops_before="$(worker_counter "${writer_worker}" kernel_write_rdma_ops)"
writer_write_completions_before="$(worker_counter "${writer_worker}" kernel_rdma_remote_write_completions)"
writer_direct_write_ops_before="$(worker_counter "${writer_worker}" kernel_rdma_direct_write_ops)"
writer_direct_write_bytes_before="$(worker_counter "${writer_worker}" kernel_rdma_direct_write_bytes)"
writer_direct_write_fallbacks_before="$(worker_counter "${writer_worker}" kernel_rdma_direct_write_fallbacks)"
writer_direct_write_errors_before="$(worker_counter "${writer_worker}" kernel_rdma_direct_write_errors)"
writer_write_direct_before="$(worker_counter "${writer_worker}" kernel_write_rdma_direct_iter_bytes)"
writer_write_bounce_before="$(worker_counter "${writer_worker}" kernel_write_rdma_bounce_copy_bytes)"
reader_read_desc_before="$(worker_counter "${reader_workers[0]}" kernel_read_rdma_desc_ops)"
reader_read_completions_before="$(worker_counter "${reader_workers[0]}" kernel_rdma_remote_read_completions)"
reader_read_direct_before="$(worker_counter "${reader_workers[0]}" kernel_read_rdma_folio_direct_bytes)"
reader_read_bounce_before="$(worker_counter "${reader_workers[0]}" kernel_read_rdma_bounce_copy_bytes)"
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
assert_counter_increased "kernel_write_rdma_direct_iter_bytes on ${writer_worker}" "${writer_write_direct_before}" "$(worker_counter "${writer_worker}" kernel_write_rdma_direct_iter_bytes)"
assert_counter_unchanged "kernel_write_rdma_bounce_copy_bytes on ${writer_worker}" "${writer_write_bounce_before}" "$(worker_counter "${writer_worker}" kernel_write_rdma_bounce_copy_bytes)"
if [ "${ASSERT_KERNEL_READ_COUNTERS}" = "true" ]; then
  assert_counter_increased "kernel_rdma_direct_read_ops on ${reader_workers[0]}" "${reader_direct_ops_before}" "$(worker_counter "${reader_workers[0]}" kernel_rdma_direct_read_ops)"
  assert_counter_increased "kernel_rdma_direct_read_bytes on ${reader_workers[0]}" "${reader_direct_bytes_before}" "$(worker_counter "${reader_workers[0]}" kernel_rdma_direct_read_bytes)"
  assert_counter_increased "kernel_read_rdma_desc_ops on ${reader_workers[0]}" "${reader_read_desc_before}" "$(worker_counter "${reader_workers[0]}" kernel_read_rdma_desc_ops)"
  assert_counter_increased "kernel_rdma_remote_read_completions on ${reader_workers[0]}" "${reader_read_completions_before}" "$(worker_counter "${reader_workers[0]}" kernel_rdma_remote_read_completions)"
  assert_counter_increased "kernel_read_rdma_folio_direct_bytes on ${reader_workers[0]}" "${reader_read_direct_before}" "$(worker_counter "${reader_workers[0]}" kernel_read_rdma_folio_direct_bytes)"
  assert_counter_unchanged "kernel_read_rdma_bounce_copy_bytes on ${reader_workers[0]}" "${reader_read_bounce_before}" "$(worker_counter "${reader_workers[0]}" kernel_read_rdma_bounce_copy_bytes)"
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
  assert_metric_increased "${writer_worker}/${WORKER_CONTAINER} native volume write commit" "${writer_metrics_before}" "${writer_metrics_after}" volume_native_rdma_write_commit_success
  assert_metric_increased "${writer_worker}/${WORKER_CONTAINER} native volume write bytes" "${writer_metrics_before}" "${writer_metrics_after}" volume_native_rdma_write_commit_bytes
  assert_metric_increased "${writer_worker}/${WORKER_CONTAINER} handler_write_rdma_prepare_ops" "${writer_metrics_before}" "${writer_metrics_after}" handler_write_rdma_prepare_ops
  assert_metric_increased "${writer_worker}/${WORKER_CONTAINER} handler_write_rdma_commit_ops" "${writer_metrics_before}" "${writer_metrics_after}" handler_write_rdma_commit_ops
  assert_metric_increased "${reader_workers[0]}/${WORKER_CONTAINER} native volume read desc" "${reader_metrics_before}" "${reader_metrics_after}" volume_native_rdma_read_desc_success
  assert_metric_increased "${reader_workers[0]}/${WORKER_CONTAINER} native volume read bytes" "${reader_metrics_before}" "${reader_metrics_after}" volume_native_rdma_read_desc_bytes
  assert_metric_increased "${reader_workers[0]}/${WORKER_CONTAINER} handler_read_rdma_prepare_replies" "${reader_metrics_before}" "${reader_metrics_after}" handler_read_rdma_prepare_replies
  assert_metric_increased "${reader_workers[0]}/${WORKER_CONTAINER} handler_read_rdma_release_replies" "${reader_metrics_before}" "${reader_metrics_after}" handler_read_rdma_release_replies
  assert_metric_unchanged "${writer_worker}/${WORKER_CONTAINER} native volume write desc errors" "${writer_metrics_before}" "${writer_metrics_after}" volume_native_rdma_write_desc_post_errors
  assert_metric_unchanged "${writer_worker}/${WORKER_CONTAINER} native volume write commit errors" "${writer_metrics_before}" "${writer_metrics_after}" volume_native_rdma_write_commit_errors
  assert_metric_unchanged "${writer_worker}/${WORKER_CONTAINER} native volume write peer errors" "${writer_metrics_before}" "${writer_metrics_after}" volume_native_rdma_write_peer_connect_errors
  assert_metric_unchanged "${reader_workers[0]}/${WORKER_CONTAINER} native volume read errors" "${reader_metrics_before}" "${reader_metrics_after}" volume_native_rdma_read_desc_errors
  assert_metric_unchanged "${reader_workers[0]}/${WORKER_CONTAINER} native volume read peer errors" "${reader_metrics_before}" "${reader_metrics_after}" volume_native_rdma_peer_connect_errors
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
