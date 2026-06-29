#!/usr/bin/env bash
# fio matrix runner for the SeaweedFS-over-RDMA kernel data path.
#
# The production gate proves correctness. This runner measures where throughput
# is lost by pairing every fio case with kernel RDMA counter deltas.
set -euo pipefail

NS="${NS:-seaweed-vfs-poc}"
CLIENT_LABEL="${CLIENT_LABEL:-app.kubernetes.io/name=seaweed-vfs-client-worker}"
WORKER_LABEL="${WORKER_LABEL:-app.kubernetes.io/name=seaweed-vfs-rdma-node-workers}"
CLIENT_CONTAINER="${CLIENT_CONTAINER:-shell}"
WORKER_CONTAINER="${WORKER_CONTAINER:-swvfs-rdma-daemon}"
CLIENT_MOUNT="${CLIENT_MOUNT:-/mnt/seaweedvfs}"
WORKER_MOUNT="${WORKER_MOUNT:-/var/lib/seaweedfs-vfs/mnt}"
WRITER_NODE="${WRITER_NODE:-hnode1}"
READER_NODE="${READER_NODE:-hnode2}"

BLOCK_SIZES="${BLOCK_SIZES:-1M 8M 16M}"
NUMJOBS="${NUMJOBS:-1 4}"
SIZES="${SIZES:-512M}"
RWS="${RWS:-write read}"
IOENGINE="${IOENGINE:-sync}"
IODEPTH="${IODEPTH:-1}"
DIRECT="${DIRECT:-0}"
FIO_EXTRA_ARGS="${FIO_EXTRA_ARGS:-}"
MIN_RDMA_RATIO="${MIN_RDMA_RATIO:-0.90}"
MAX_FALLBACK_DELTA="${MAX_FALLBACK_DELTA:-0}"
MAX_ERROR_DELTA="${MAX_ERROR_DELTA:-0}"
ENFORCE_RATIO="${ENFORCE_RATIO:-true}"
ENFORCE_FALLBACKS="${ENFORCE_FALLBACKS:-true}"
DROP_CACHES="${DROP_CACHES:-true}"
CLEANUP="${CLEANUP:-false}"
RDMA_MIN_BS_BYTES="${RDMA_MIN_BS_BYTES:-262144}"
MATRIX_ID="${MATRIX_ID:-$(date +%Y%m%d-%H%M%S)}"
REPORT_DIR="${REPORT_DIR:-/tmp/seaweedfs-rdma-fio-matrix-${MATRIX_ID}}"

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

ensure_fio() {
  local pod=$1
  exec_client "${pod}" '
    set -euo pipefail
    if ! command -v fio >/dev/null 2>&1; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y --no-install-recommends fio ca-certificates coreutils
    fi
  '
}

assert_mounts() {
  local client=$1
  local worker=$2
  exec_client "${client}" "grep -q ' ${CLIENT_MOUNT} ' /proc/mounts && grep ' ${CLIENT_MOUNT} ' /proc/mounts"
  exec_worker "${worker}" "grep -q ' ${WORKER_MOUNT} ' /proc/mounts && grep ' ${WORKER_MOUNT} ' /proc/mounts"
}

drop_caches() {
  local worker=$1
  is_truthy "${DROP_CACHES}" || return 0
  exec_worker "${worker}" "sync; echo 3 > /proc/sys/vm/drop_caches" >/dev/null
}

counter_names() {
  cat <<'EOF'
kernel_rdma_direct_read_ops
kernel_rdma_direct_read_bytes
kernel_rdma_direct_read_fallbacks
kernel_rdma_direct_read_errors
kernel_read_rdma_desc_ops
kernel_read_rdma_folio_direct_bytes
kernel_read_rdma_bounce_copy_bytes
kernel_rdma_read_prepare_batch_ops
kernel_rdma_read_prepare_batch_descs
kernel_rdma_read_prepare_batch_fallbacks
kernel_rdma_remote_read_posts
kernel_rdma_remote_read_completions
kernel_rdma_remote_read_failures
kernel_rdma_remote_read_bytes
kernel_rdma_direct_write_ops
kernel_rdma_direct_write_bytes
kernel_rdma_direct_write_fallbacks
kernel_rdma_direct_write_errors
kernel_write_rdma_ops
kernel_write_rdma_bounce_copy_bytes
kernel_write_rdma_pagecache_write_ops
kernel_write_rdma_pagecache_write_bytes
kernel_write_rdma_pagecache_writeback_ops
kernel_write_rdma_pagecache_writeback_bytes
kernel_write_rdma_pagecache_writeback_fallbacks
kernel_write_rdma_pagecache_writeback_errors
kernel_rdma_write_prepare_batch_ops
kernel_rdma_write_prepare_batch_descs
kernel_rdma_write_prepare_batch_fallbacks
kernel_rdma_remote_write_posts
kernel_rdma_remote_write_completions
kernel_rdma_remote_write_failures
kernel_rdma_remote_write_bytes
kernel_rdma_send_batches
kernel_rdma_send_batch_wrs
kernel_rdma_send_max_batch_wrs
kernel_rdma_connection_slot_misses
EOF
}

snapshot_counters() {
  local pod=$1
  local names
  names="$(counter_names | tr '\n' ' ')"
  exec_worker "${pod}" "
    set -eu
    for counter in ${names}; do
      value=\$(cat \"/sys/module/seaweedvfs/parameters/\${counter}\" 2>/dev/null || printf 0)
      printf '%s=%s\n' \"\${counter}\" \"\${value}\"
    done
  "
}

size_to_bytes() {
  python3 - "$1" <<'PY'
import re
import sys

raw = sys.argv[1].strip()
match = re.fullmatch(r"(\d+)([KkMmGgTt]?)", raw)
if not match:
    raise SystemExit(f"invalid size: {raw}")
value = int(match.group(1))
unit = match.group(2).lower()
scale = {"": 1, "k": 1024, "m": 1024**2, "g": 1024**3, "t": 1024**4}[unit]
print(value * scale)
PY
}

fio_case() {
  local pod=$1
  local rw=$2
  local bs=$3
  local size=$4
  local numjobs=$5
  local dataset=$6
  local case_id=$7
  local out_file=$8
  local fsync_arg=()

  if [ "${rw}" = "write" ] || [ "${rw}" = "randwrite" ]; then
    fsync_arg=(--fsync_on_close=1)
  fi

  exec_client "${pod}" "
    set -euo pipefail
    mkdir -p '${CLIENT_MOUNT}/rdma-fio-matrix-${MATRIX_ID}'
    /usr/bin/fio \
      --name='${case_id}' \
      --directory='${CLIENT_MOUNT}/rdma-fio-matrix-${MATRIX_ID}' \
      --filename_format='${dataset}.\$jobnum' \
      --rw='${rw}' \
      --bs='${bs}' \
      --size='${size}' \
      --numjobs='${numjobs}' \
      --ioengine='${IOENGINE}' \
      --iodepth='${IODEPTH}' \
      --direct='${DIRECT}' \
      --group_reporting \
      --output-format=json \
      ${fsync_arg[*]} \
      ${FIO_EXTRA_ARGS}
  " >"${out_file}"
}

prepare_read_dataset() {
  local pod=$1
  local bs=$2
  local size=$3
  local numjobs=$4
  local dataset=$5

  exec_client "${pod}" "
    set -euo pipefail
    mkdir -p '${CLIENT_MOUNT}/rdma-fio-matrix-${MATRIX_ID}'
    missing=false
    for job in \$(seq 0 $((numjobs - 1))); do
      [ -s '${CLIENT_MOUNT}/rdma-fio-matrix-${MATRIX_ID}/${dataset}.'\"\${job}\" ] || missing=true
    done
    if [ \"\${missing}\" = true ]; then
      /usr/bin/fio \
        --name='prep-${dataset}' \
        --directory='${CLIENT_MOUNT}/rdma-fio-matrix-${MATRIX_ID}' \
        --filename_format='${dataset}.\$jobnum' \
        --rw=write \
        --bs='${bs}' \
        --size='${size}' \
        --numjobs='${numjobs}' \
        --ioengine='${IOENGINE}' \
        --iodepth='${IODEPTH}' \
        --direct='${DIRECT}' \
        --group_reporting \
        --fsync_on_close=1 >/dev/null
    fi
  "
}

append_report() {
  local case_id=$1
  local rw=$2
  local bs=$3
  local size=$4
  local numjobs=$5
  local worker=$6
  local before=$7
  local after=$8
  local fio_json=$9
  local tsv_file=${10}
  local jsonl_file=${11}
  local bs_bytes

  bs_bytes="$(size_to_bytes "${bs}")"
  CASE_ID="${case_id}" \
  RW="${rw}" \
  BS="${bs}" \
  BS_BYTES="${bs_bytes}" \
  SIZE="${size}" \
  NUMJOBS="${numjobs}" \
  WORKER="${worker}" \
  MIN_RDMA_RATIO="${MIN_RDMA_RATIO}" \
  MAX_FALLBACK_DELTA="${MAX_FALLBACK_DELTA}" \
  MAX_ERROR_DELTA="${MAX_ERROR_DELTA}" \
  ENFORCE_RATIO="${ENFORCE_RATIO}" \
  ENFORCE_FALLBACKS="${ENFORCE_FALLBACKS}" \
  RDMA_MIN_BS_BYTES="${RDMA_MIN_BS_BYTES}" \
  BEFORE_COUNTERS="${before}" \
  AFTER_COUNTERS="${after}" \
  FIO_JSON="$(cat "${fio_json}")" \
  TSV_FILE="${tsv_file}" \
  JSONL_FILE="${jsonl_file}" \
  python3 - <<'PY'
import json
import os
import sys

def parse_kv(raw):
    out = {}
    for line in raw.splitlines():
        if not line or "=" not in line:
            continue
        key, value = line.split("=", 1)
        try:
            out[key] = int(value)
        except ValueError:
            out[key] = 0
    return out

def truthy(raw):
    return str(raw).lower() in ("1", "true", "yes", "y")

def delta(name):
    return after.get(name, 0) - before.get(name, 0)

def fio_totals(doc, rw):
    total_bytes = 0
    runtime_ms = 0
    total_iops = 0.0
    for job in doc.get("jobs", []):
        section = job.get("read" if "read" in rw else "write", {})
        total_bytes += int(section.get("io_bytes") or 0)
        runtime_ms = max(runtime_ms, int(section.get("runtime") or 0))
        total_iops += float(section.get("iops") or 0.0)
    bw_mib_s = 0.0
    if runtime_ms > 0:
        bw_mib_s = total_bytes / (runtime_ms / 1000.0) / (1024 * 1024)
    return total_bytes, runtime_ms, total_iops, bw_mib_s

case_id = os.environ["CASE_ID"]
rw = os.environ["RW"]
before = parse_kv(os.environ.get("BEFORE_COUNTERS", ""))
after = parse_kv(os.environ.get("AFTER_COUNTERS", ""))
fio = json.loads(os.environ["FIO_JSON"])
app_bytes, runtime_ms, iops, bw_mib_s = fio_totals(fio, rw)

if "read" in rw:
    rdma_bytes = delta("kernel_read_rdma_folio_direct_bytes")
    remote_bytes = delta("kernel_rdma_remote_read_bytes")
    direct_ops = delta("kernel_rdma_direct_read_ops")
    remote_posts = delta("kernel_rdma_remote_read_posts")
    remote_completions = delta("kernel_rdma_remote_read_completions")
    fallback_delta = (
        delta("kernel_rdma_direct_read_fallbacks")
        + delta("kernel_rdma_read_prepare_batch_fallbacks")
    )
    error_delta = (
        delta("kernel_rdma_direct_read_errors")
        + delta("kernel_rdma_remote_read_failures")
    )
    bounce_delta = delta("kernel_read_rdma_bounce_copy_bytes")
else:
    rdma_bytes = delta("kernel_rdma_direct_write_bytes")
    remote_bytes = delta("kernel_rdma_remote_write_bytes")
    direct_ops = delta("kernel_rdma_direct_write_ops")
    remote_posts = delta("kernel_rdma_remote_write_posts")
    remote_completions = delta("kernel_rdma_remote_write_completions")
    fallback_delta = (
        delta("kernel_rdma_direct_write_fallbacks")
        + delta("kernel_rdma_write_prepare_batch_fallbacks")
        + delta("kernel_write_rdma_pagecache_writeback_fallbacks")
    )
    error_delta = (
        delta("kernel_rdma_direct_write_errors")
        + delta("kernel_rdma_remote_write_failures")
        + delta("kernel_write_rdma_pagecache_writeback_errors")
    )
    bounce_delta = delta("kernel_write_rdma_bounce_copy_bytes")

ratio = (rdma_bytes / app_bytes) if app_bytes else 0.0
small_io = int(os.environ["BS_BYTES"]) < int(os.environ["RDMA_MIN_BS_BYTES"])
max_batch_wrs = after.get("kernel_rdma_send_max_batch_wrs", 0)
send_batch_wrs = delta("kernel_rdma_send_batch_wrs")
send_batches = delta("kernel_rdma_send_batches")
status = "pass"
reasons = []

if truthy(os.environ["ENFORCE_RATIO"]) and not small_io and ratio < float(os.environ["MIN_RDMA_RATIO"]):
    status = "fail"
    reasons.append(f"rdma_ratio={ratio:.3f}")
if truthy(os.environ["ENFORCE_FALLBACKS"]) and fallback_delta > int(os.environ["MAX_FALLBACK_DELTA"]):
    status = "fail"
    reasons.append(f"fallback_delta={fallback_delta}")
if truthy(os.environ["ENFORCE_FALLBACKS"]) and error_delta > int(os.environ["MAX_ERROR_DELTA"]):
    status = "fail"
    reasons.append(f"error_delta={error_delta}")
if bounce_delta != 0:
    status = "fail"
    reasons.append(f"bounce_delta={bounce_delta}")

record = {
    "case": case_id,
    "rw": rw,
    "bs": os.environ["BS"],
    "size": os.environ["SIZE"],
    "numjobs": int(os.environ["NUMJOBS"]),
    "worker": os.environ["WORKER"],
    "runtime_ms": runtime_ms,
    "app_bytes": app_bytes,
    "rdma_bytes": rdma_bytes,
    "remote_bytes": remote_bytes,
    "rdma_ratio": ratio,
    "bw_mib_s": bw_mib_s,
    "iops": iops,
    "direct_ops": direct_ops,
    "remote_posts": remote_posts,
    "remote_completions": remote_completions,
    "send_batches": send_batches,
    "send_batch_wrs": send_batch_wrs,
    "send_max_batch_wrs": max_batch_wrs,
    "fallback_delta": fallback_delta,
    "error_delta": error_delta,
    "bounce_delta": bounce_delta,
    "small_io": small_io,
    "status": status,
    "reasons": reasons,
}

line = "\t".join(
    [
        record["case"],
        record["rw"],
        record["bs"],
        record["size"],
        str(record["numjobs"]),
        f"{record['bw_mib_s']:.2f}",
        f"{record['iops']:.2f}",
        str(record["app_bytes"]),
        str(record["rdma_bytes"]),
        str(record["remote_bytes"]),
        f"{record['rdma_ratio']:.4f}",
        str(record["direct_ops"]),
        str(record["remote_posts"]),
        str(record["remote_completions"]),
        str(record["send_batches"]),
        str(record["send_batch_wrs"]),
        str(record["send_max_batch_wrs"]),
        str(record["fallback_delta"]),
        str(record["error_delta"]),
        str(record["bounce_delta"]),
        record["status"],
        ",".join(record["reasons"]),
    ]
)
with open(os.environ["TSV_FILE"], "a", encoding="utf-8") as fh:
    fh.write(line + "\n")
with open(os.environ["JSONL_FILE"], "a", encoding="utf-8") as fh:
    fh.write(json.dumps(record, sort_keys=True) + "\n")
print(line)
if status != "pass":
    sys.exit(2)
PY
}

mkdir -p "${REPORT_DIR}"
summary_tsv="${REPORT_DIR}/summary.tsv"
summary_jsonl="${REPORT_DIR}/summary.jsonl"
raw_dir="${REPORT_DIR}/raw"
mkdir -p "${raw_dir}"

cat >"${summary_tsv}" <<'EOF'
case	rw	bs	size	numjobs	bw_mib_s	iops	app_bytes	rdma_bytes	remote_bytes	rdma_ratio	direct_ops	remote_posts	remote_completions	send_batches	send_batch_wrs	send_max_batch_wrs	fallback_delta	error_delta	bounce_delta	status	reasons
EOF
: >"${summary_jsonl}"

log "Resolving pods"
writer_client="$(client_pod "${WRITER_NODE}")"
reader_client="$(client_pod "${READER_NODE}")"
writer_worker="$(worker_pod "${WRITER_NODE}")"
reader_worker="$(worker_pod "${READER_NODE}")"

log "Checking mounts"
assert_mounts "${writer_client}" "${writer_worker}"
assert_mounts "${reader_client}" "${reader_worker}"

log "Ensuring fio is installed"
ensure_fio "${writer_client}"
ensure_fio "${reader_client}"

log "Writing reports under ${REPORT_DIR}"
failures=0

for size in ${SIZES}; do
  for bs in ${BLOCK_SIZES}; do
    for numjobs in ${NUMJOBS}; do
      dataset="dataset-size${size}-bs${bs}-nj${numjobs}"
      for rw in ${RWS}; do
        case_id="${rw}-size${size}-bs${bs}-nj${numjobs}"
        raw_json="${raw_dir}/${case_id}.json"
        if [[ "${rw}" == *read* ]]; then
          pod="${reader_client}"
          worker="${reader_worker}"
          log "Preparing read dataset ${dataset}"
          prepare_read_dataset "${writer_client}" "${bs}" "${size}" "${numjobs}" "${dataset}"
          drop_caches "${reader_worker}"
        else
          pod="${writer_client}"
          worker="${writer_worker}"
          drop_caches "${writer_worker}"
        fi
        before="$(snapshot_counters "${worker}")"
        log "Running ${case_id} on ${worker}"
        fio_case "${pod}" "${rw}" "${bs}" "${size}" "${numjobs}" "${dataset}" "${case_id}" "${raw_json}"
        after="$(snapshot_counters "${worker}")"
        if ! append_report "${case_id}" "${rw}" "${bs}" "${size}" "${numjobs}" "${worker}" "${before}" "${after}" "${raw_json}" "${summary_tsv}" "${summary_jsonl}"; then
          failures=$((failures + 1))
        fi
      done
    done
  done
done

if is_truthy "${CLEANUP}"; then
  log "Cleaning matrix data from ${CLIENT_MOUNT}/rdma-fio-matrix-${MATRIX_ID}"
  exec_client "${writer_client}" "rm -rf '${CLIENT_MOUNT}/rdma-fio-matrix-${MATRIX_ID}'"
fi

log "Summary"
column -t -s $'\t' "${summary_tsv}" || cat "${summary_tsv}"

if [ "${failures}" -ne 0 ]; then
  die "${failures} fio matrix case(s) failed RDMA ratio/fallback/error checks; see ${REPORT_DIR}"
fi

log "RDMA fio matrix passed; report=${REPORT_DIR}"
