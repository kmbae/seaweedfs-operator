{{/*
RDMA annotations, volumes, volumeMounts, sidecars for a volume group or volumeTopology entry.
Usage: {{- include "seaweedfs.rdmaVolumeGroup" . | nindent 4 }}
*/}}
{{- define "seaweedfs.rdmaSidecarsOnly" -}}
{{- if .Values.rdma.enabled }}
{{- $rdmaMode := default "sriov" .Values.rdma.mode }}
- name: rdma-engine
  image: {{ printf "%s/rdma-engine:%s" .Values.rdma.registry .Values.rdma.engineTag }}
  imagePullPolicy: {{ .Values.rdma.imagePullPolicy }}
  command:
    - ./rdma-engine-server
    - --debug
    {{- if .Values.rdma.deviceName }}
    - --device
    - {{ .Values.rdma.deviceName | quote }}
    {{- end }}
    - --ipc-socket
    - /tmp/rdma/rdma-engine.sock
    - --port
    - {{ .Values.rdma.listenPort | quote }}
    {{- if .Values.rdma.realInitRetries }}
    - --real-init-retries
    - {{ .Values.rdma.realInitRetries | quote }}
    {{- end }}
    {{- if .Values.rdma.realInitRetryIntervalMs }}
    - --real-init-retry-interval-ms
    - {{ .Values.rdma.realInitRetryIntervalMs | quote }}
    {{- end }}
  env:
    {{- if eq $rdmaMode "hostPF" }}
    - name: POD_IP
      valueFrom:
        fieldRef:
          fieldPath: status.podIP
    {{- end }}
    - name: VOLUME_SERVER_URL
      value: "http://127.0.0.1:8081/local-volume"
    - name: VOLUME_SERVER_GRPC_URL
      value: "http://$(POD_IP):8444"
    - name: SEAWEEDFS_RDMA_VOLUME_GRPC_READ
      value: "true"
    {{- if .Values.rdma.volumeGrpcMaxMessageBytes }}
    - name: SEAWEEDFS_RDMA_VOLUME_GRPC_MAX_MESSAGE_BYTES
      value: {{ .Values.rdma.volumeGrpcMaxMessageBytes | quote }}
    {{- end }}
    - name: VOLUME_DATA_DIR
      value: "/data0"
    - name: VOLUME_IDX_DIR
      value: "/data0"
    - name: RDMA_LISTEN_PORT
      value: {{ .Values.rdma.listenPort | quote }}
    - name: RDMA_ENGINE_METRICS_ADDR
      value: "0.0.0.0:18085"
    {{- if .Values.rdma.ucxTls }}
    - name: UCX_TLS
      value: {{ .Values.rdma.ucxTls | quote }}
    {{- end }}
    {{- if .Values.rdma.ucxNetDevices }}
    - name: UCX_NET_DEVICES
      value: {{ .Values.rdma.ucxNetDevices | quote }}
    {{- else if and (eq $rdmaMode "hostPF") .Values.rdma.deviceName }}
    - name: UCX_NET_DEVICES
      value: {{ printf "%s:1" .Values.rdma.deviceName | quote }}
    {{- end }}
  securityContext:
    {{- if eq $rdmaMode "hostPF" }}
    privileged: true
    runAsUser: 0
    runAsGroup: 0
    {{- end }}
    capabilities:
      add:
        - IPC_LOCK
        {{- if eq $rdmaMode "hostPF" }}
        - NET_ADMIN
        - SYS_ADMIN
        - SYS_RESOURCE
        {{- end }}
  resources:
    {{- if eq $rdmaMode "hostPF" }}
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      memory: 1Gi
    {{- else }}
    limits:
      memory: {{ .Values.rdma.hugepages2Mi }}
      {{ .Values.rdma.mlnxnicResource }}: "1"
      hugepages-2Mi: {{ .Values.rdma.hugepages2Mi }}
    requests:
      memory: {{ .Values.rdma.hugepages2Mi }}
      {{ .Values.rdma.mlnxnicResource }}: "1"
      hugepages-2Mi: {{ .Values.rdma.hugepages2Mi }}
    {{- end }}
  volumeMounts:
    - name: rdma-socket
      mountPath: /tmp/rdma
    - name: mount0
      mountPath: /data0
      readOnly: true
    {{- if eq $rdmaMode "hostPF" }}
    - name: dev-infiniband
      mountPath: /dev/infiniband
    {{- end }}
  ports:
    - name: rdma-net
      containerPort: {{ .Values.rdma.listenPort }}
    - name: rdma-metrics
      containerPort: 18085
- name: rdma-sidecar
  image: {{ printf "%s/rdma-sidecar:%s" .Values.rdma.registry .Values.rdma.sidecarTag }}
  imagePullPolicy: {{ .Values.rdma.imagePullPolicy }}
  {{- if eq $rdmaMode "hostPF" }}
  env:
    - name: POD_IP
      valueFrom:
        fieldRef:
          fieldPath: status.podIP
  {{- end }}
  args:
    - --port=8081
    - --engine-socket=/tmp/rdma/rdma-engine.sock
    {{- if eq $rdmaMode "hostPF" }}
    - --volume-server=http://$(POD_IP):8444
    {{- else }}
    - --volume-server={{ .Values.rdma.volumeServerURL }}
    {{- end }}
    - --volume-data-dir=/data0
    - --enable-rdma=true
    {{- if .Values.rdma.enablePayloadRDMA }}
    - --enable-payload-rdma=true
    {{- end }}
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
{{- $rdmaMode := default "sriov" .Values.rdma.mode }}
{{- if ne $rdmaMode "hostPF" }}
annotations:
  k8s.v1.cni.cncf.io/networks: {{ .Values.rdma.multusNetwork | quote }}
{{- end }}
volumes:
  - name: rdma-socket
    emptyDir: {}
  {{- if eq $rdmaMode "hostPF" }}
  - name: dev-infiniband
    hostPath:
      path: /dev/infiniband
      type: Directory
  {{- end }}
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
      {{- if .Values.rdma.deviceName }}
      - --device
      - {{ .Values.rdma.deviceName | quote }}
      {{- end }}
      - --ipc-socket
      - /tmp/rdma/rdma-engine.sock
      - --port
      - {{ .Values.rdma.listenPort | quote }}
      {{- if .Values.rdma.realInitRetries }}
      - --real-init-retries
      - {{ .Values.rdma.realInitRetries | quote }}
      {{- end }}
      {{- if .Values.rdma.realInitRetryIntervalMs }}
      - --real-init-retry-interval-ms
      - {{ .Values.rdma.realInitRetryIntervalMs | quote }}
      {{- end }}
    env:
      {{- if eq $rdmaMode "hostPF" }}
      - name: POD_IP
        valueFrom:
          fieldRef:
            fieldPath: status.podIP
      {{- end }}
      - name: VOLUME_SERVER_URL
        value: "http://127.0.0.1:8081/local-volume"
      - name: VOLUME_SERVER_GRPC_URL
        value: "http://$(POD_IP):8444"
      - name: SEAWEEDFS_RDMA_VOLUME_GRPC_READ
        value: "true"
      {{- if .Values.rdma.volumeGrpcMaxMessageBytes }}
      - name: SEAWEEDFS_RDMA_VOLUME_GRPC_MAX_MESSAGE_BYTES
        value: {{ .Values.rdma.volumeGrpcMaxMessageBytes | quote }}
      {{- end }}
      - name: VOLUME_DATA_DIR
        value: "/data0"
      - name: VOLUME_IDX_DIR
        value: "/data0"
      - name: RDMA_LISTEN_PORT
        value: {{ .Values.rdma.listenPort | quote }}
      - name: RDMA_ENGINE_METRICS_ADDR
        value: "0.0.0.0:18085"
      {{- if .Values.rdma.ucxTls }}
      - name: UCX_TLS
        value: {{ .Values.rdma.ucxTls | quote }}
      {{- end }}
      {{- if .Values.rdma.ucxNetDevices }}
      - name: UCX_NET_DEVICES
        value: {{ .Values.rdma.ucxNetDevices | quote }}
      {{- else if and (eq $rdmaMode "hostPF") .Values.rdma.deviceName }}
      - name: UCX_NET_DEVICES
        value: {{ printf "%s:1" .Values.rdma.deviceName | quote }}
      {{- end }}
    securityContext:
      {{- if eq $rdmaMode "hostPF" }}
      privileged: true
      runAsUser: 0
      runAsGroup: 0
      {{- end }}
      capabilities:
        add:
          - IPC_LOCK
          {{- if eq $rdmaMode "hostPF" }}
          - NET_ADMIN
          - SYS_ADMIN
          - SYS_RESOURCE
          {{- end }}
    resources:
      {{- if eq $rdmaMode "hostPF" }}
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        memory: 1Gi
      {{- else }}
      limits:
        memory: {{ .Values.rdma.hugepages2Mi }}
        {{ .Values.rdma.mlnxnicResource }}: "1"
        hugepages-2Mi: {{ .Values.rdma.hugepages2Mi }}
      requests:
        memory: {{ .Values.rdma.hugepages2Mi }}
        {{ .Values.rdma.mlnxnicResource }}: "1"
        hugepages-2Mi: {{ .Values.rdma.hugepages2Mi }}
      {{- end }}
    volumeMounts:
      - name: rdma-socket
        mountPath: /tmp/rdma
      - name: mount0
        mountPath: /data0
        readOnly: true
      {{- if eq $rdmaMode "hostPF" }}
      - name: dev-infiniband
        mountPath: /dev/infiniband
      {{- end }}
    ports:
      - name: rdma-net
        containerPort: {{ .Values.rdma.listenPort }}
      - name: rdma-metrics
        containerPort: 18085
  - name: rdma-sidecar
    image: {{ printf "%s/rdma-sidecar:%s" .Values.rdma.registry .Values.rdma.sidecarTag }}
    imagePullPolicy: {{ .Values.rdma.imagePullPolicy }}
    {{- if eq $rdmaMode "hostPF" }}
    env:
      - name: POD_IP
        valueFrom:
          fieldRef:
            fieldPath: status.podIP
    {{- end }}
    args:
      - --port=8081
      - --engine-socket=/tmp/rdma/rdma-engine.sock
      {{- if eq $rdmaMode "hostPF" }}
      - --volume-server=http://$(POD_IP):8444
      {{- else }}
      - --volume-server={{ .Values.rdma.volumeServerURL }}
      {{- end }}
      - --volume-data-dir=/data0
      - --enable-rdma=true
      {{- if .Values.rdma.enablePayloadRDMA }}
      - --enable-payload-rdma=true
      {{- end }}
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
