{{- define "seaweedfs.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "seaweedfs.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "seaweedfs.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "seaweedfs.labels" -}}
helm.sh/chart: {{ include "seaweedfs.chart" . }}
app.kubernetes.io/name: {{ include "seaweedfs.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Resolve admin credentials secret name.
*/}}
{{- define "seaweedfs.adminSecretName" -}}
{{- .Values.admin.credentialsSecret.name | default (printf "%s-admin-credentials" (.Values.name | default .Release.Name)) -}}
{{- end }}

{{/*
Resolve S3 config secret name.
*/}}
{{- define "seaweedfs.s3SecretName" -}}
{{- .Values.filer.s3.configSecret.name | default (printf "%s-s3-config" (.Values.name | default .Release.Name)) -}}
{{- end }}

{{/*
Seaweed CR name used for Service names (e.g. seaweedfs-admin).
*/}}
{{- define "seaweedfs.clusterName" -}}
{{- .Values.name | default .Release.Name -}}
{{- end }}
