#!/usr/bin/env bash
# Run pjd/pjdfstest against the Seaweed VFS kernel mount in a POC client pod.
set -euo pipefail

NS="${NS:-seaweed-vfs-poc}"
POD="${POD:-seaweed-vfs-client-hnode1}"
MOUNT_DIR="${MOUNT_DIR:-/mnt/seaweedvfs}"
PJDFSTEST_REPO="${PJDFSTEST_REPO:-https://github.com/pjd/pjdfstest.git}"
PJDFSTEST_REF="${PJDFSTEST_REF:-ededbeb2b44929972898afb87474b0937f78a877}"
PJDFSTEST_WORK_DIR="${PJDFSTEST_WORK_DIR:-/tmp/pjdfstest-src}"
PJDFSTEST_TESTS="${PJDFSTEST_TESTS:-tests/open/25.t tests/unlink/14.t tests/open/26.t tests/mkdir/00.t tests/rename/20.t tests/rename/24.t}"

if command -v kubectl >/dev/null 2>&1; then
  KUBECTL=(kubectl)
elif command -v microk8s >/dev/null 2>&1; then
  KUBECTL=(microk8s kubectl)
else
  echo "ERROR: kubectl not found" >&2
  exit 1
fi

echo "==> Running pjdfstest in ${NS}/${POD}"
echo "    mount: ${MOUNT_DIR}"
echo "    tests: ${PJDFSTEST_TESTS}"

"${KUBECTL[@]}" -n "${NS}" exec -i "${POD}" -- env \
  MOUNT_DIR="${MOUNT_DIR}" \
  PJDFSTEST_REPO="${PJDFSTEST_REPO}" \
  PJDFSTEST_REF="${PJDFSTEST_REF}" \
  PJDFSTEST_WORK_DIR="${PJDFSTEST_WORK_DIR}" \
  PJDFSTEST_TESTS="${PJDFSTEST_TESTS}" \
  bash -s <<'REMOTE'
set -euo pipefail

need_packages=()
for bin in git make autoreconf gcc prove openssl; do
  if ! command -v "${bin}" >/dev/null 2>&1; then
    need_packages+=(1)
    break
  fi
done

if [ "${#need_packages[@]}" -gt 0 ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends \
    ca-certificates git make autoconf automake gcc libc6-dev perl openssl
fi

if ! mount | grep -q " on ${MOUNT_DIR} type seaweedvfs "; then
  echo "ERROR: ${MOUNT_DIR} is not a seaweedvfs mount" >&2
  mount | grep seaweedvfs >&2 || true
  exit 1
fi

if [ ! -d "${PJDFSTEST_WORK_DIR}/.git" ]; then
  git clone "${PJDFSTEST_REPO}" "${PJDFSTEST_WORK_DIR}"
fi
git -C "${PJDFSTEST_WORK_DIR}" remote set-url origin "${PJDFSTEST_REPO}"
git -C "${PJDFSTEST_WORK_DIR}" fetch --depth 1 origin "${PJDFSTEST_REF}"
git -C "${PJDFSTEST_WORK_DIR}" checkout --detach FETCH_HEAD

(
  cd "${PJDFSTEST_WORK_DIR}"
  autoreconf -ifs
  ./configure
  make pjdfstest
)

test_root="${MOUNT_DIR}/pjdfstest-root-$(date +%s)-$$"
mkdir -p "${test_root}"
cleanup() {
  rm -rf "${test_root}"
}
trap cleanup EXIT

cd "${test_root}"
IFS=' ' read -r -a tests <<< "${PJDFSTEST_TESTS}"
resolved_tests=()
for test_path in "${tests[@]}"; do
  case "${test_path}" in
    /*)
      resolved_tests+=("${test_path}")
      ;;
    *)
      resolved_tests+=("${PJDFSTEST_WORK_DIR}/${test_path}")
      ;;
  esac
done
echo "==> cwd: $(pwd)"
echo "==> helper: ${PJDFSTEST_WORK_DIR}/pjdfstest"
echo "==> prove -rv ${resolved_tests[*]}"
prove -rv "${resolved_tests[@]}"
REMOTE
