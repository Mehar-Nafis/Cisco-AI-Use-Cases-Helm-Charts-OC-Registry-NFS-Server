{{/*
Expand the name of the chart.
*/}}
{{- define "vss.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Full name: release-name (truncated to 63 chars).
*/}}
{{- define "vss.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Chart label: name-version
*/}}
{{- define "vss.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels applied to every resource.
*/}}
{{- define "vss.labels" -}}
helm.sh/chart: {{ include "vss.chart" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}

{{/*
Selector labels for a given component.
Usage: {{ include "vss.selectorLabels" (dict "root" . "component" "via-server") }}
*/}}
{{- define "vss.selectorLabels" -}}
app.kubernetes.io/name: {{ include "vss.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
Service Account name.
*/}}
{{- define "vss.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (printf "%s-sa" (include "vss.fullname" .)) .Values.serviceAccount.name }}
{{- else -}}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
PVC storage class helper – returns storageClass if set, else cluster default.
Usage: {{ include "vss.storageClass" (dict "global" .Values.persistence.storageClass "local" .Values.persistence.redisData.storageClass) }}
*/}}
{{- define "vss.storageClass" -}}
{{- $sc := .local | default .global -}}
{{- if $sc -}}
storageClassName: {{ $sc | quote }}
{{- end }}
{{- end }}

{{/*
Internal service DNS name for a component.
Usage: {{ include "vss.svcName" (dict "root" . "component" "redis") }}
*/}}
{{- define "vss.svcName" -}}
{{- printf "%s-%s" .root.Release.Name .component }}
{{- end }}

{{/*
OpenShift Route host helper.
Usage: {{ include "vss.routeHost" (dict "root" . "prefix" "api-gateway") }}
*/}}
{{- define "vss.routeHost" -}}
{{- if .root.Values.route.baseDomain -}}
{{- printf "%s-%s.%s" .root.Release.Name .prefix .root.Values.route.baseDomain }}
{{- end }}
{{- end }}

{{- define "vss.podSecurityContext" }}
securityContext:
  # runAsNonRoot removed—vendor images (via-server, storage-ms) run as root
  # runAsUser/runAsGroup/fsGroup removed for OpenShift SCC range compatibility
  # seccompProfile removed—anyuid SCC forbids explicit seccomp settings
{{- end }}

{{- define "vss.containerSecurityContext" }}
allowPrivilegeEscalation: false
capabilities:
  drop:
    - ALL
# runAsNonRoot removed—vendor images (redis, nginx, etc.) run as root
# runAsUser removed to avoid SCC UID range mismatch (OpenShift assigned UID)
# seccompProfile removed—anyuid SCC forbids explicit seccomp settings
{{- end }}

{{/*
Relaxed pod security context for vendor images (e.g. storage-ms, via-server)
that embed files owned by a specific UID and cannot run as an arbitrary UID.
Requires the service account to be bound to 'anyuid' SCC:
  oc adm policy add-scc-to-user anyuid -z vss-sa -n <namespace>
Note: runAsUser/runAsGroup intentionally omitted – let the image's Dockerfile USER
directive or OpenShift's anyuid SCC assign the appropriate UID.
Note: fsGroup intentionally omitted – setting fsGroup causes Kubernetes to chown
all local-pv files, conflicting with OpenShift's auto-assigned GID. Let the SCC
supply the supplemental group.
Note: seccompProfile omitted because anyuid SCC does not allow explicit seccomp settings.
*/}}
{{- define "vss.anyuidPodSecurityContext" }}
securityContext: {}
{{- end }}

{{- define "vss.anyuidContainerSecurityContext" }}
capabilities:
  drop:
    - ALL
# Confirmed live: an empty/unset securityContext isn't enough to escape
# restricted-v2 — OpenShift's admission auto-fills its own required
# runAsUser/runAsNonRoot/fsGroup/seccompProfile defaults onto any pod that
# doesn't explicitly conflict with it, and admits under restricted-v2
# regardless of what else the SA is authorized for (confirmed via the live
# pod's actual .spec.securityContext, none of which came from this chart).
# vss.podSecurityContext's own comment already said these vendor images
# "run as root" — so force that explicitly to create a real conflict with
# restricted-v2's non-root requirement, which is what actually triggers
# fallback to the anyuid SCC.
runAsUser: 0
runAsNonRoot: false
# Confirmed live (round 2): even admitted under anyuid as root, launch_vst
# still failed with "Permission denied" — but a debug pod's `ls -la`/
# `head -c 100` on the exact same binary showed correct rwxr-xr-x ELF
# permissions (readable/executable by owner, group, AND other). Standard
# Unix DAC permission bits can't explain a denial when "other" already has
# the execute bit — that points at SELinux (MAC), not file permissions.
# anyuid's SELinux strategy is still MustRunAs (confined); only the
# privileged SCC uses RunAsAny (unconfined/spc_t). vss-sa already has
# `privileged` granted (`oc adm policy add-scc-to-user privileged -z
# vss-sa -n <namespace>`) but the pod was landing on anyuid anyway, since
# nothing in the spec forced the fallback — requesting `privileged: true`
# here is the one thing anyuid can't satisfy, forcing OpenShift to select
# the privileged SCC instead.
privileged: true
{{- end }}

{{/*
nodeSelector block – targets GPU nodes by product label based on gpuType.

  gpuType=l40s  → nvidia.com/gpu.product: NVIDIA-L40S  (wn1 or wn2)
  gpuType=rtx   → nvidia.com/gpu.product: NVIDIA-RTX-PRO-6000-Blackwell-Server-Edition (c845)

If nodeSelector.forcedNode is set, it pins all pods to a specific host.
For l40s: pods may land on wn1 or wn2. local-fs WaitForFirstConsumer
ensures all pods sharing a PVC are automatically co-located on the same node.

Usage: {{- include "vss.nodeSelector" . | nindent 6 }}
*/}}
{{/*
Mutual anti-affinity to split primary and secondary pods across two L40S nodes.

Primary pods (via-server, storage-ms, etc.) consume 5 PVs on one node.
Secondary pods (redis, nim-llm) consume 2 PVs on the other node.

Mutual = works regardless of which group the scheduler processes first:
  - If a primary pod lands on node A first, secondary pods are pushed to node B.
  - If a secondary pod lands on node A first, primary pods are pushed to node B,
    and their shared PVCs bind to node B.

Disabled when forcedNode is set (single-node override, no split needed).
*/}}

{{/*
Both affinity rules below were requiredDuringSchedulingIgnoredDuringExecution
(hard) originally — that assumes at least 2 nodes carry the GPU nodeSelector
label, one per mutually-exclusive group. Confirmed live on this cluster
(oc get nodes -l nvidia.com/gpu.product=...) that only ONE node (c845) has
the RTX6000 Blackwell label, the same single-node pool the insurguard chart
targets — with only 1 qualifying node, the hard requirement can never be
satisfied and every pod in both groups just sits Pending forever. Softened
to preferredDuringSchedulingIgnoredDuringExecution, matching the
spread-preference (not spread-requirement) pattern insurguard's own
gpuTopologySpread/nimAntiAffinity helpers already use. If this cluster ever
gets a second RTX6000 node, the preference will actually spread pods across
both; on the current single-node pool, it now just lets everything co-locate
instead of blocking scheduling entirely.
*/}}
{{- define "vss.primaryAffinity" -}}
{{- if and .Values.nodeSelector.enabled (not .Values.nodeSelector.forcedNode) }}
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchExpressions:
              - key: app.kubernetes.io/component
                operator: In
                values:
                  - redis
                  - nim-llm
          topologyKey: kubernetes.io/hostname
{{- end }}
{{- end }}

{{- define "vss.secondaryAffinity" -}}
{{- if and .Values.nodeSelector.enabled (not .Values.nodeSelector.forcedNode) }}
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchExpressions:
              - key: app.kubernetes.io/component
                operator: In
                values:
                  - via-server
                  - storage-ms
                  - nv-cv-event-detector
          topologyKey: kubernetes.io/hostname
{{- end }}
{{- end }}

{{- define "vss.nodeSelector" -}}
{{- if .Values.nodeSelector.enabled }}
  {{- if .Values.nodeSelector.forcedNode }}
nodeSelector:
  kubernetes.io/hostname: {{ .Values.nodeSelector.forcedNode }}
  node-role.kubernetes.io/worker: ""
  {{- else if eq .Values.gpuType "l40s" }}
nodeSelector:
  nvidia.com/gpu.product: NVIDIA-L40S-SHARED
  node-role.kubernetes.io/worker: ""
  {{- else if eq .Values.gpuType "rtx" }}
nodeSelector:
  nvidia.com/gpu.product: NVIDIA-RTX-PRO-6000-Blackwell-Server-Edition-SHARED
  node-role.kubernetes.io/worker: ""
  {{- end }}
{{- end }}
{{- end }}
