#!/usr/bin/env bash
# Validate the SeaweedVFS kernel-RDMA POC path without touching hnode4.
set -euo pipefail

NS="${NS:-seaweed-vfs-poc}"
SELECTOR="${SELECTOR:-app.kubernetes.io/name=seaweed-vfs-rdma-node-workers}"
MNT="${MNT:-/var/lib/seaweedfs-vfs/mnt}"
SIZE_MB="${SIZE_MB:-16}"
READ_BS_MB="${READ_BS_MB:-1}"
RUN_FIO="${RUN_FIO:-auto}"
RUN_PJDFSTEST="${RUN_PJDFSTEST:-auto}"
RUN_FAILOVER="${RUN_FAILOVER:-false}"
FAILOVER_NODE="${FAILOVER_NODE:-hnode2}"
SMOKE_FILE="${SMOKE_FILE:-${MNT}/rdma-production-smoke-${SIZE_MB}m.bin}"
SMOKE_SHA=""

KUBECTL=("${KUBECTL:-kubectl}")
if command -v microk8s >/dev/null 2>&1; then
  KUBECTL=(microk8s kubectl)
fi

kctl() { "${KUBECTL[@]}" "$@"; }

pod_for_node() {
  local node="$1"
  kctl -n "$NS" get pod -l "$SELECTOR" \
    --field-selector "spec.nodeName=${node}" \
    -o jsonpath='{.items[0].metadata.name}'
}

exec_pod() {
  local pod="$1"
  shift
  kctl -n "$NS" exec "$pod" -c swvfs-rdma-daemon -- "$@"
}

exec_sh() {
  local pod="$1"
  shift
  exec_pod "$pod" sh -lc "$*"
}

print_kernel_counters() {
  local pod="$1"
  echo "== kernel counters: ${pod} =="
  exec_sh "$pod" '
    for p in \
      kernel_read_ops kernel_read_bytes kernel_read_total_ns \
      kernel_read_daemon_submit_ns kernel_read_reply_copy_bytes \
      kernel_read_rdma_desc_ops kernel_read_rdma_desc_ns \
	      kernel_read_rdma_wr_ns kernel_read_rdma_bounce_copy_bytes \
	      kernel_read_rdma_folio_direct_ops kernel_read_rdma_folio_direct_bytes \
		      kernel_rdma_direct_read_ops kernel_rdma_direct_read_bytes \
		      kernel_rdma_direct_read_fallbacks kernel_rdma_direct_read_errors \
		      kernel_rdma_read_prepare_batch_ops kernel_rdma_read_prepare_batch_descs \
		      kernel_rdma_read_prepare_batch_fallbacks \
	      rdma_write_window_ios kernel_rdma_write_prepare_batch_ops \
	      kernel_rdma_write_prepare_batch_descs \
	      kernel_rdma_write_prepare_batch_fallbacks \
		      kernel_read_window_cache_hits kernel_read_window_cache_misses \
      kernel_read_window_cache_bytes \
      kernel_rdma_remote_read_posts kernel_rdma_remote_read_completions \
      kernel_rdma_remote_read_failures kernel_rdma_remote_read_bytes \
      kernel_rdma_send_batches kernel_rdma_send_batch_wrs \
      kernel_rdma_send_max_batch_wrs \
      kernel_rdma_read_release_posts kernel_rdma_read_release_completions \
      kernel_rdma_read_release_failures kernel_write_ops kernel_write_bytes \
      kernel_write_total_ns kernel_write_daemon_submit_ns \
      kernel_write_copy_from_iter_bytes kernel_write_rdma_ops \
      kernel_rdma_direct_write_ops kernel_rdma_direct_write_bytes \
      kernel_rdma_direct_write_fallbacks kernel_rdma_direct_write_errors \
      kernel_write_rdma_prepare_ns kernel_write_rdma_wr_ns \
      kernel_write_rdma_commit_ns kernel_write_rdma_bounce_copy_bytes \
      kernel_write_rdma_direct_iter_bytes kernel_write_rdma_fallbacks \
      kernel_write_rdma_deferred_queued kernel_write_rdma_deferred_flushed \
      kernel_write_rdma_deferred_flushes kernel_write_rdma_deferred_errors \
      kernel_write_rdma_commit_batch_ops kernel_write_rdma_commit_batch_entries \
      kernel_write_rdma_commit_batch_errors \
      kernel_rdma_remote_write_posts \
      kernel_rdma_remote_write_completions kernel_rdma_remote_write_failures \
      kernel_rdma_remote_write_bytes; do
        f="/sys/module/seaweedvfs/parameters/${p}"
        [ -r "$f" ] && printf "%s=%s\n" "$p" "$(cat "$f")"
    done
  '
}

print_daemon_metrics() {
  local pod="$1"
  echo "== daemon metrics: ${pod} =="
  exec_sh "$pod" '
    if command -v curl >/dev/null 2>&1; then
      curl -fsS http://127.0.0.1:18084/metrics || true
    elif command -v wget >/dev/null 2>&1; then
      wget -qO- http://127.0.0.1:18084/metrics || true
    else
      echo "curl/wget not found in pod; skip daemon metrics"
    fi
  '
}

counter_value() {
  local pod="$1"
  local name="$2"
  exec_sh "$pod" "cat '/sys/module/seaweedvfs/parameters/${name}' 2>/dev/null || printf 0"
}

assert_counter_increased() {
  local label="$1"
  local before="$2"
  local after="$3"
  if [ "${after}" -le "${before}" ]; then
    echo "ERROR: ${label} did not increase: before=${before} after=${after}" >&2
    exit 1
  fi
  echo "OK: ${label} increased: before=${before} after=${after}"
}

assert_counter_unchanged() {
  local label="$1"
  local before="$2"
  local after="$3"
  if [ "${after}" -ne "${before}" ]; then
    echo "ERROR: ${label} changed: before=${before} after=${after}" >&2
    exit 1
  fi
  echo "OK: ${label} unchanged: ${after}"
}

require_ready() {
  kctl -n "$NS" rollout status ds/seaweed-vfs-rdma-node-workers --timeout=180s
  kctl -n "$NS" get pod -l "$SELECTOR" -o wide
}

run_read_write_smoke() {
  local src="$1"
  local dst="$2"
  local file="${SMOKE_FILE}"
  local sum_src
  local sum_dst

  echo "== write ${SIZE_MB}MiB from ${src} =="
  exec_sh "$src" "
    { time dd if=/dev/urandom of='${file}' bs=1M count='${SIZE_MB}' conv=fsync status=none; } 2>&1
    bytes=\$(stat -c %s '${file}')
    printf 'bytes=%s\n' \"\$bytes\"
  "
  sum_src="$(exec_sh "$src" "sha256sum '${file}' | awk '{print \$1}'")"

  echo "== large-block read ${SIZE_MB}MiB from ${dst} =="
  exec_sh "$dst" "
    { time dd if='${file}' of=/dev/null bs='${READ_BS_MB}'M status=none; } 2>&1
    bytes=\$(stat -c %s '${file}')
    printf 'bytes=%s\n' \"\$bytes\"
  "

  echo "== checksum read ${SIZE_MB}MiB from ${dst} =="
  sum_dst="$(exec_sh "$dst" "dd if='${file}' bs='${READ_BS_MB}'M status=none | sha256sum | awk '{print \$1}'")"
  if [ "$sum_src" != "$sum_dst" ]; then
    echo "ERROR: checksum mismatch: src=${sum_src} dst=${sum_dst}" >&2
    exit 1
  fi
  SMOKE_SHA="$sum_src"
  exec_sh "$dst" "wc -c '${file}'"
}

run_optional_fio() {
  local pod="$1"
  case "$RUN_FIO" in
    false|0|no) return 0 ;;
  esac
  echo "== fio check: ${pod} =="
  if ! exec_sh "$pod" "command -v fio >/dev/null 2>&1"; then
    echo "fio not found in worker image; set RUN_FIO=false to silence this skip"
    return 0
  fi
  exec_sh "$pod" "
    fio --name=swvfs-rdma-smoke \
      --directory='${MNT}' \
      --filename=fio-rdma-smoke.bin \
      --rw=readwrite --bs=1M --size='${SIZE_MB}'M \
      --iodepth=4 --numjobs=1 --direct=0 --time_based=0 \
      --group_reporting
  "
}

run_optional_pjdfstest() {
  local pod="$1"
  case "$RUN_PJDFSTEST" in
    false|0|no) return 0 ;;
  esac
  echo "== pjdfstest check: ${pod} =="
  if ! exec_sh "$pod" "[ -d /opt/pjdfstest ] && command -v prove >/dev/null 2>&1"; then
    echo "pjdfstest/prove not found in worker image; set RUN_PJDFSTEST=false to silence this skip"
    return 0
  fi
  exec_sh "$pod" "
    mkdir -p '${MNT}/pjdfstest-rdma'
    cd /opt/pjdfstest
    PJDFSTEST_DIR='${MNT}/pjdfstest-rdma' prove -r tests
  "
}

run_optional_failover() {
  case "$RUN_FAILOVER" in
    true|1|yes) ;;
    *) return 0 ;;
  esac
  local node="${1:-$FAILOVER_NODE}"
  local file="${2:-$SMOKE_FILE}"
  local expected_sha="${3:-$SMOKE_SHA}"
  local victim
  local replacement=""
  victim="$(pod_for_node "$node")"
  if [ -z "$victim" ]; then
    echo "ERROR: no RDMA worker pod found on failover node ${node}" >&2
    exit 1
  fi
  echo "== failover: deleting ${victim} on ${node} and waiting for replacement =="
  kctl -n "$NS" delete pod "$victim" --wait=true
  for _ in $(seq 1 90); do
    replacement="$(pod_for_node "$node" || true)"
    if [ -n "$replacement" ] && [ "$replacement" != "$victim" ]; then
      break
    fi
    sleep 2
  done
  if [ -z "$replacement" ] || [ "$replacement" = "$victim" ]; then
    echo "ERROR: replacement pod did not appear on ${node}" >&2
    exit 1
  fi
  kctl -n "$NS" wait --for=condition=Ready "pod/${replacement}" --timeout=180s
  exec_sh "$replacement" "grep -q ' ${MNT} ' /proc/mounts && grep ' ${MNT} ' /proc/mounts"
  if [ -n "$expected_sha" ]; then
    local replacement_sha
    replacement_sha=""
    for _ in $(seq 1 60); do
      replacement_sha="$(exec_sh "$replacement" "dd if='${file}' bs='${READ_BS_MB}'M status=none | sha256sum | awk '{print \$1}'" 2>/dev/null || true)"
      if [ "$replacement_sha" = "$expected_sha" ]; then
        break
      fi
      sleep 2
    done
    if [ "$replacement_sha" != "$expected_sha" ]; then
      echo "ERROR: checksum mismatch after failover: expected=${expected_sha} got=${replacement_sha}" >&2
      exit 1
    fi
  fi
  require_ready
}

main() {
  require_ready
  local src dst
  src="$(pod_for_node hnode1)"
  dst="$(pod_for_node hnode2)"
  if [ -z "$src" ] || [ -z "$dst" ]; then
    echo "ERROR: expected hnode1 and hnode2 worker pods" >&2
    exit 1
  fi

  print_kernel_counters "$src"
  print_kernel_counters "$dst"
  local src_write_ops_before src_write_completions_before
  local src_direct_write_ops_before src_direct_write_bytes_before
  local src_direct_write_fallbacks_before src_direct_write_errors_before
  local src_write_direct_before src_write_bounce_before
  local dst_read_desc_before dst_read_completions_before
  local dst_read_direct_before dst_read_bounce_before
  src_write_ops_before="$(counter_value "$src" kernel_write_rdma_ops)"
  src_write_completions_before="$(counter_value "$src" kernel_rdma_remote_write_completions)"
  src_direct_write_ops_before="$(counter_value "$src" kernel_rdma_direct_write_ops)"
  src_direct_write_bytes_before="$(counter_value "$src" kernel_rdma_direct_write_bytes)"
  src_direct_write_fallbacks_before="$(counter_value "$src" kernel_rdma_direct_write_fallbacks)"
  src_direct_write_errors_before="$(counter_value "$src" kernel_rdma_direct_write_errors)"
  src_write_direct_before="$(counter_value "$src" kernel_write_rdma_direct_iter_bytes)"
  src_write_bounce_before="$(counter_value "$src" kernel_write_rdma_bounce_copy_bytes)"
  dst_read_desc_before="$(counter_value "$dst" kernel_read_rdma_desc_ops)"
  dst_read_completions_before="$(counter_value "$dst" kernel_rdma_remote_read_completions)"
  dst_read_direct_before="$(counter_value "$dst" kernel_read_rdma_folio_direct_bytes)"
  dst_read_bounce_before="$(counter_value "$dst" kernel_read_rdma_bounce_copy_bytes)"
  run_read_write_smoke "$src" "$dst"
  run_optional_fio "$dst"
  run_optional_pjdfstest "$dst"
  assert_counter_increased "kernel_write_rdma_ops on writer" "$src_write_ops_before" "$(counter_value "$src" kernel_write_rdma_ops)"
  assert_counter_increased "kernel_rdma_remote_write_completions on writer" "$src_write_completions_before" "$(counter_value "$src" kernel_rdma_remote_write_completions)"
  assert_counter_increased "kernel_rdma_direct_write_ops on writer" "$src_direct_write_ops_before" "$(counter_value "$src" kernel_rdma_direct_write_ops)"
  assert_counter_increased "kernel_rdma_direct_write_bytes on writer" "$src_direct_write_bytes_before" "$(counter_value "$src" kernel_rdma_direct_write_bytes)"
  assert_counter_unchanged "kernel_rdma_direct_write_fallbacks on writer" "$src_direct_write_fallbacks_before" "$(counter_value "$src" kernel_rdma_direct_write_fallbacks)"
  assert_counter_unchanged "kernel_rdma_direct_write_errors on writer" "$src_direct_write_errors_before" "$(counter_value "$src" kernel_rdma_direct_write_errors)"
  assert_counter_increased "kernel_write_rdma_direct_iter_bytes on writer" "$src_write_direct_before" "$(counter_value "$src" kernel_write_rdma_direct_iter_bytes)"
  assert_counter_unchanged "kernel_write_rdma_bounce_copy_bytes on writer" "$src_write_bounce_before" "$(counter_value "$src" kernel_write_rdma_bounce_copy_bytes)"
  assert_counter_increased "kernel_read_rdma_desc_ops on reader" "$dst_read_desc_before" "$(counter_value "$dst" kernel_read_rdma_desc_ops)"
  assert_counter_increased "kernel_rdma_remote_read_completions on reader" "$dst_read_completions_before" "$(counter_value "$dst" kernel_rdma_remote_read_completions)"
  assert_counter_increased "kernel_read_rdma_folio_direct_bytes on reader" "$dst_read_direct_before" "$(counter_value "$dst" kernel_read_rdma_folio_direct_bytes)"
  assert_counter_unchanged "kernel_read_rdma_bounce_copy_bytes on reader" "$dst_read_bounce_before" "$(counter_value "$dst" kernel_read_rdma_bounce_copy_bytes)"
  print_kernel_counters "$src"
  print_kernel_counters "$dst"
  print_daemon_metrics "$src"
  print_daemon_metrics "$dst"
  run_optional_failover "$FAILOVER_NODE" "$SMOKE_FILE" "$SMOKE_SHA"
}

main "$@"
