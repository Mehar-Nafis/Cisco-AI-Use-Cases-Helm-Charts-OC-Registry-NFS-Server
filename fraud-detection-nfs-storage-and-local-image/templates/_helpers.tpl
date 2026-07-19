{{/*
Expand the name of the chart.
*/}}
{{- define "fraud-detection.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "fraud-detection.fullname" -}}
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

{{/*
Common labels
*/}}
{{- define "fraud-detection.labels" -}}
helm.sh/chart: {{ include "fraud-detection.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: fraud-detection
{{- end }}

{{/*
Selector labels for a component
Usage: {{ include "fraud-detection.selectorLabels" (dict "component" "backend") }}
*/}}
{{- define "fraud-detection.selectorLabels" -}}
app: {{ .component }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
Image pull secrets block
*/}}
{{- define "fraud-detection.imagePullSecrets" -}}
{{- if .Values.global.imagePullSecrets }}
imagePullSecrets:
{{- range .Values.global.imagePullSecrets }}
  - name: {{ .name }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Pod-level security context for OpenShift (non-root)
*/}}
{{- define "fraud-detection.podSecurityContext" -}}
securityContext:
  runAsNonRoot: true
{{- end }}

{{/*
Container-level security context for OpenShift
*/}}
{{- define "fraud-detection.containerSecurityContext" -}}
securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop:
      - ALL
{{- end }}

{{/*
Node selector using existing NVIDIA GPU product labels.
gpuType "l40s"    → nvidia.com/gpu.product=NVIDIA-L40S-SHARED  (wn1, wn2)
gpuType "rtx6000" → nvidia.com/gpu.product=NVIDIA-RTX-PRO-6000-Blackwell-Server-Edition-SHARED (c845)
*/}}
{{- define "fraud-detection.nodeSelector" -}}
nodeSelector:
  {{- if eq .Values.nodeDeployment.gpuType "rtx6000" }}
  nvidia.com/gpu.product: NVIDIA-RTX-PRO-6000-Blackwell-Server-Edition-SHARED
  {{- else }}
  nvidia.com/gpu.product: NVIDIA-L40S-SHARED
  {{- end }}
{{- end }}

