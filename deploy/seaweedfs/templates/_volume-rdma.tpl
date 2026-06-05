{{/*
RDMA annotations, volumes, volumeMounts, sidecars for a volume group or volumeTopology entry.
Usage: {{- include "seaweedfs.rdmaVolumeGroup" . | nindent 4 }}
*/}}
{{- define "seaweedfs.rdmaSidecarsOnly" -}}
{{- if .Values.rdma.enabled }}
- name: rdma-engine
  image: {{ printf "%s/rdma-engine:%s" .Values.rdma.registry .Values.rdma.engineTag }}
  imagePullPolicy: {{ .Values.rdma.imagePullPolicy }}
  command:
    - ./rdma-engine-server
    - --debug
    - --ipc-socket
    - /tmp/rdma/rdma-engine.sock
    - --port
    - {{ .Values.rdma.listenPort | quote }}
  env:
    - name: VOLUME_SERVER_URL
      value: {{ .Values.rdma.volumeServerURL | quote }}
    - name: RDMA_LISTEN_PORT
      value: {{ .Values.rdma.listenPort | quote }}
  securityContext:
    capabilities:
      add: ["IPC_LOCK"]
  resources:
    limits:
      memory: {{ .Values.rdma.hugepages2Mi }}
      {{ .Values.rdma.mlnxnicResource }}: "1"
      hugepages-2Mi: {{ .Values.rdma.hugepages2Mi }}
    requests:
      memory: {{ .Values.rdma.hugepages2Mi }}
      {{ .Values.rdma.mlnxnicResource }}: "1"
      hugepages-2Mi: {{ .Values.rdma.hugepages2Mi }}
  volumeMounts:
    - name: rdma-socket
      mountPath: /tmp/rdma
  ports:
    - name: rdma-net
      containerPort: {{ .Values.rdma.listenPort }}
- name: rdma-sidecar
  image: {{ printf "%s/rdma-sidecar:%s" .Values.rdma.registry .Values.rdma.sidecarTag }}
  imagePullPolicy: {{ .Values.rdma.imagePullPolicy }}
  args:
    - --port=8081
    - --engine-socket=/tmp/rdma/rdma-engine.sock
    - --volume-server={{ .Values.rdma.volumeServerURL }}
    - --volume-data-dir=/data0
    - --enable-rdma=true
  ports:
    - name: rdma-http
      containerPort: 8081
  volumeMounts:
    - name: rdma-socket
      mountPath: /tmp/rdma
    - name: mount0
      mountPath: /data0
      readOnly: true
{{- end }}
{{- end }}

{{- define "seaweedfs.rdmaVolumeGroup" -}}
{{- if .Values.rdma.enabled }}
annotations:
  k8s.v1.cni.cncf.io/networks: {{ .Values.rdma.multusNetwork | quote }}
volumes:
  - name: rdma-socket
    emptyDir: {}
volumeMounts:
  - name: rdma-socket
    mountPath: /tmp/rdma
sidecars:
  - name: rdma-engine
    image: {{ printf "%s/rdma-engine:%s" .Values.rdma.registry .Values.rdma.engineTag }}
    imagePullPolicy: {{ .Values.rdma.imagePullPolicy }}
    command:
      - ./rdma-engine-server
      - --debug
      - --ipc-socket
      - /tmp/rdma/rdma-engine.sock
      - --port
      - {{ .Values.rdma.listenPort | quote }}
    env:
      - name: VOLUME_SERVER_URL
        value: {{ .Values.rdma.volumeServerURL | quote }}
      - name: RDMA_LISTEN_PORT
        value: {{ .Values.rdma.listenPort | quote }}
    securityContext:
      capabilities:
        add: ["IPC_LOCK"]
    resources:
      limits:
        memory: {{ .Values.rdma.hugepages2Mi }}
        {{ .Values.rdma.mlnxnicResource }}: "1"
        hugepages-2Mi: {{ .Values.rdma.hugepages2Mi }}
      requests:
        memory: {{ .Values.rdma.hugepages2Mi }}
        {{ .Values.rdma.mlnxnicResource }}: "1"
        hugepages-2Mi: {{ .Values.rdma.hugepages2Mi }}
    volumeMounts:
      - name: rdma-socket
        mountPath: /tmp/rdma
    ports:
      - name: rdma-net
        containerPort: {{ .Values.rdma.listenPort }}
  - name: rdma-sidecar
    image: {{ printf "%s/rdma-sidecar:%s" .Values.rdma.registry .Values.rdma.sidecarTag }}
    imagePullPolicy: {{ .Values.rdma.imagePullPolicy }}
    args:
      - --port=8081
      - --engine-socket=/tmp/rdma/rdma-engine.sock
      - --volume-server={{ .Values.rdma.volumeServerURL }}
      - --volume-data-dir=/data0
      - --enable-rdma=true
    ports:
      - name: rdma-http
        containerPort: 8081
    volumeMounts:
      - name: rdma-socket
        mountPath: /tmp/rdma
      - name: mount0
        mountPath: /data0
        readOnly: true
{{- end }}
{{- end }}
