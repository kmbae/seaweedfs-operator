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
      kernel_rdma_remote_read_posts kernel_rdma_remote_read_completions \
      kernel_rdma_remote_read_failures kernel_rdma_remote_read_bytes \
      kernel_rdma_read_release_posts kernel_rdma_read_release_completions \
      kernel_rdma_read_release_failures kernel_write_ops kernel_write_bytes \
      kernel_write_total_ns kernel_write_daemon_submit_ns \
      kernel_write_copy_from_iter_bytes kernel_write_rdma_ops \
      kernel_write_rdma_prepare_ns kernel_write_rdma_wr_ns \
      kernel_write_rdma_commit_ns kernel_write_rdma_bounce_copy_bytes \
      kernel_write_rdma_fallbacks kernel_rdma_remote_write_posts \
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

require_ready() {
  kctl -n "$NS" rollout status ds/seaweed-vfs-rdma-node-workers --timeout=180s
  kctl -n "$NS" get pod -l "$SELECTOR" -o wide
}

run_read_write_smoke() {
  local src="$1"
  local dst="$2"
  local file="${MNT}/rdma-production-smoke-${SIZE_MB}m.bin"
  local sum_src
  local sum_dst

  echo "== write ${SIZE_MB}MiB from ${src} =="
  exec_sh "$src" "
    start=\$(date +%s%N)
    dd if=/dev/zero of='${file}' bs=1M count='${SIZE_MB}' conv=fsync status=none
    end=\$(date +%s%N)
    bytes=\$(stat -c %s '${file}')
    elapsed=\$((end - start))
    printf 'bytes=%s elapsed_ns=%s\n' \"\$bytes\" \"\$elapsed\"
  "
  sum_src="$(exec_sh "$src" "dd if=/dev/zero bs=1M count='${SIZE_MB}' status=none | sha256sum | awk '{print \$1}'")"

  echo "== large-block read ${SIZE_MB}MiB from ${dst} =="
  exec_sh "$dst" "
    start=\$(date +%s%N)
    dd if='${file}' of=/dev/null bs='${READ_BS_MB}'M status=none
    end=\$(date +%s%N)
    bytes=\$(stat -c %s '${file}')
    elapsed=\$((end - start))
    printf 'bytes=%s elapsed_ns=%s\n' \"\$bytes\" \"\$elapsed\"
  "

  echo "== checksum read ${SIZE_MB}MiB from ${dst} =="
  sum_dst="$(exec_sh "$dst" "dd if='${file}' bs='${READ_BS_MB}'M status=none | sha256sum | awk '{print \$1}'")"
  if [ "$sum_src" != "$sum_dst" ]; then
    echo "ERROR: checksum mismatch: src=${sum_src} dst=${sum_dst}" >&2
    exit 1
  fi
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
  local victim
  victim="$(kctl -n "$NS" get pod -l "$SELECTOR" -o jsonpath='{.items[0].metadata.name}')"
  echo "== failover: deleting ${victim} and waiting for DaemonSet recovery =="
  kctl -n "$NS" delete pod "$victim" --wait=false
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
  run_read_write_smoke "$src" "$dst"
  run_optional_fio "$dst"
  run_optional_pjdfstest "$dst"
  print_kernel_counters "$src"
  print_kernel_counters "$dst"
  print_daemon_metrics "$src"
  print_daemon_metrics "$dst"
  run_optional_failover
}

main "$@"
