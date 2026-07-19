{{/*
Expand the chart name.
*/}}
{{- define "chat-assistance.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels applied to every resource.
*/}}
{{- define "chat-assistance.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}

{{/*
Standard security context for non-root OpenShift containers.
Usage: {{- include "chat-assistance.securityContext" . | nindent 12 }}
*/}}
{{- define "chat-assistance.securityContext" -}}
allowPrivilegeEscalation: false
runAsNonRoot: true
seccompProfile:
  type: RuntimeDefault
capabilities:
  drop:
    - ALL
{{- end }}

{{/*
Infra resource block.
*/}}
{{- define "chat-assistance.resources.infra" -}}
requests:
  cpu: {{ .Values.resources.infra.requests.cpu }}
  memory: {{ .Values.resources.infra.requests.memory }}
limits:
  cpu: {{ .Values.resources.infra.limits.cpu }}
  memory: {{ .Values.resources.infra.limits.memory }}
{{- end }}

{{/*
Backend resource block.
*/}}
{{- define "chat-assistance.resources.backend" -}}
requests:
  cpu: {{ .Values.resources.backend.requests.cpu }}
  memory: {{ .Values.resources.backend.requests.memory }}
limits:
  cpu: {{ .Values.resources.backend.limits.cpu }}
  memory: {{ .Values.resources.backend.limits.memory }}
{{- end }}

{{/*
NVIDIA resource block (adds GPU limit).
*/}}
{{- define "chat-assistance.resources.nvidia" -}}
requests:
  cpu: {{ .Values.resources.nvidia.requests.cpu }}
  memory: {{ .Values.resources.nvidia.requests.memory }}
limits:
  cpu: {{ .Values.resources.nvidia.limits.cpu }}
  memory: {{ .Values.resources.nvidia.limits.memory }}
  nvidia.com/gpu: {{ .Values.nvidia.gpuCount }}
{{- end }}

{{/*
Frontend resource block.
*/}}
{{/*
Global nodeSelector block.
Emits nodeSelector only when .Values.nodeSelector is non-empty.
Usage: {{- include "chat-assistance.nodeSelector" . | nindent 6 }}
*/}}
{{- define "chat-assistance.nodeSelector" -}}
{{- if .Values.nodeSelector }}
nodeSelector:
  {{- toYaml .Values.nodeSelector | nindent 2 }}
{{- end }}
{{- end }}

{{/*
Topology spread constraint for GPU workloads.
Disabled when nodeSelector is set (spreading across nodes is irrelevant when pinned).
Usage: {{- include "chat-assistance.gpuSpread" . | nindent 8 }}
*/}}
{{- define "chat-assistance.gpuSpread" -}}
{{- if not .Values.nodeSelector }}
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        gpu-workload: "true"
{{- end }}
{{- end }}

{{- define "chat-assistance.resources.frontend" -}}
requests:
  cpu: {{ .Values.resources.frontend.requests.cpu }}
  memory: {{ .Values.resources.frontend.requests.memory }}
limits:
  cpu: {{ .Values.resources.frontend.limits.cpu }}
  memory: {{ .Values.resources.frontend.limits.memory }}
{{- end }}

{{/*
Anti-affinity for NIM GPU pods.
Spreads NIM workloads across nodes (preferred) so each physical L40S hosts at most one NIM,
allowing full kvCachePercent utilisation without cross-slice OOM.
Usage: {{- include "chat-assistance.nimAntiAffinity" . | nindent 6 }}
*/}}
{{- define "chat-assistance.nimAntiAffinity" -}}
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchLabels:
              gpu-workload: "true"
          topologyKey: kubernetes.io/hostname
{{- end }}
