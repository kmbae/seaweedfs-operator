#!/usr/bin/env bash
# Install the locally patched seaweedvfs kernel module on the worker POC nodes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KMOD_DIR="${KMOD_DIR:-"${SCRIPT_DIR}/../../../seaweedvfs-kmod"}"
NAMESPACE="${NAMESPACE:-seaweed-vfs-poc}"
CONFIGMAP="${CONFIGMAP:-seaweed-vfs-patched-kmod-source}"
NODES="${NODES:-hnode1 hnode2 hnode3}"
KUBECTL_BIN="${KUBECTL_BIN:-microk8s kubectl}"

# shellcheck disable=SC2206
KUBECTL=(${KUBECTL_BIN})

required_files=(
  Makefile
  compat.h
  dkms.conf
  seaweedvfs.c
  swvfs_proto.h
  compat-probes/file_lock_core.c
  compat-probes/inode_state_read.c
)

for file in "${required_files[@]}"; do
  if [ ! -f "${KMOD_DIR}/${file}" ]; then
    echo "ERROR: missing kmod source file: ${KMOD_DIR}/${file}" >&2
    exit 1
  fi
done

"${KUBECTL[@]}" create namespace "${NAMESPACE}" --dry-run=client -o yaml \
  | "${KUBECTL[@]}" apply -f -

"${KUBECTL[@]}" -n "${NAMESPACE}" create configmap "${CONFIGMAP}" \
  --from-file=Makefile="${KMOD_DIR}/Makefile" \
  --from-file=compat.h="${KMOD_DIR}/compat.h" \
  --from-file=dkms.conf="${KMOD_DIR}/dkms.conf" \
  --from-file=seaweedvfs.c="${KMOD_DIR}/seaweedvfs.c" \
  --from-file=swvfs_proto.h="${KMOD_DIR}/swvfs_proto.h" \
  --from-file=file_lock_core.c="${KMOD_DIR}/compat-probes/file_lock_core.c" \
  --from-file=inode_state_read.c="${KMOD_DIR}/compat-probes/inode_state_read.c" \
  --dry-run=client -o yaml \
  | "${KUBECTL[@]}" apply -f -

for node in ${NODES}; do
  job="seaweed-vfs-patched-kmod-${node}"
  "${KUBECTL[@]}" -n "${NAMESPACE}" delete job "${job}" --ignore-not-found --wait=true
  cat <<YAML | "${KUBECTL[@]}" apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: seaweed-vfs-patched-kmod
    app.kubernetes.io/part-of: seaweed-vfs-poc
    seaweedfs.io/poc-node: ${node}
spec:
  backoffLimit: 0
  template:
    metadata:
      labels:
        app.kubernetes.io/name: seaweed-vfs-patched-kmod
        app.kubernetes.io/part-of: seaweed-vfs-poc
        seaweedfs.io/poc-node: ${node}
    spec:
      restartPolicy: Never
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      nodeSelector:
        kubernetes.io/hostname: ${node}
      tolerations:
        - operator: Exists
      containers:
        - name: install
          image: ubuntu:24.04
          imagePullPolicy: IfNotPresent
          securityContext:
            privileged: true
          command:
            - /bin/bash
            - -lc
          args:
            - |
              set -euo pipefail
              work=/host/var/tmp/seaweedvfs-kmod-rdma
              rm -rf "\${work}"
              install -d -m 0755 "\${work}/compat-probes"
              cp /kmod-src/Makefile "\${work}/"
              cp /kmod-src/compat.h "\${work}/"
              cp /kmod-src/dkms.conf "\${work}/"
              cp /kmod-src/seaweedvfs.c "\${work}/"
              cp /kmod-src/swvfs_proto.h "\${work}/"
              cp /kmod-src/file_lock_core.c "\${work}/compat-probes/"
              cp /kmod-src/inode_state_read.c "\${work}/compat-probes/"
              chroot /host /bin/bash -lc '
                set -euo pipefail
                export DEBIAN_FRONTEND=noninteractive
                if ! command -v make >/dev/null 2>&1 || [ ! -e "/lib/modules/\$(uname -r)/build/Makefile" ]; then
                  apt-get update
                  apt-get install -y build-essential "linux-headers-\$(uname -r)" kmod
                fi
                cd /var/tmp/seaweedvfs-kmod-rdma
                make clean >/dev/null 2>&1 || true
                make
                modinfo ./seaweedvfs.ko
                modinfo -F parm ./seaweedvfs.ko | grep -E "rdma_(read|write)_hints"
                install_dir="/lib/modules/\$(uname -r)/updates/dkms"
                rm -f "\${install_dir}/seaweedvfs.ko" \
                  "\${install_dir}/seaweedvfs.ko.zst" \
                  "\${install_dir}/seaweedvfs.ko.xz" \
                  "\${install_dir}/seaweedvfs.ko.gz"
                install -D -m 0644 seaweedvfs.ko "\${install_dir}/seaweedvfs.ko"
                depmod -a "\$(uname -r)"
                modinfo seaweedvfs
                modinfo -F parm seaweedvfs | grep -E "rdma_(read|write)_hints"
              '
          volumeMounts:
            - name: kmod-source
              mountPath: /kmod-src
              readOnly: true
            - name: host-root
              mountPath: /host
            - name: host-proc
              mountPath: /host/proc
            - name: host-sys
              mountPath: /host/sys
            - name: host-dev
              mountPath: /host/dev
            - name: host-run
              mountPath: /host/run
      volumes:
        - name: kmod-source
          configMap:
            name: ${CONFIGMAP}
        - name: host-root
          hostPath:
            path: /
            type: Directory
        - name: host-proc
          hostPath:
            path: /proc
            type: Directory
        - name: host-sys
          hostPath:
            path: /sys
            type: Directory
        - name: host-dev
          hostPath:
            path: /dev
            type: Directory
        - name: host-run
          hostPath:
            path: /run
            type: Directory
YAML
done

wait_args=()
for node in ${NODES}; do
  wait_args+=("job/seaweed-vfs-patched-kmod-${node}")
done

"${KUBECTL[@]}" -n "${NAMESPACE}" wait --for=condition=complete "${wait_args[@]}" --timeout=30m
