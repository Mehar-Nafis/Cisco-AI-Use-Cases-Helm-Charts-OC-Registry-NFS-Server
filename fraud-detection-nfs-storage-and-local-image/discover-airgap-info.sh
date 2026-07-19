#!/usr/bin/env bash
# Read-only discovery helper for making nim-llm air-gapped — adapted from
# the equivalent script in the insurguard chart. This chart carries the same
# app.kubernetes.io/part-of=fraud-detection label insurguard does, so PVCs
# are found the same way (label selector, not fixed names).
#
# Answers: the real localModelPath value for nim-llm — read the cached
# snapshot directory name straight off the nim-cache/nim-hf-cache PVCs (no
# NIM/NGC involvement, just a directory listing).
#
# IMPORTANT CAVEAT this script can't resolve: nim-llm's image
# (cisco_fraud_detection:nim_llm) is a custom-tagged rebuild, not the same
# nvcr.io image insurguard/vss-helm/chat-assistant use — whether it's even
# nim_llm_sdk-based (and therefore whether NIM_MODEL_NAME does anything at
# all here) was NOT confirmed by reading its source, unlike those other
# charts. If section 1 below finds a plausible snapshot path but setting
# localModelPath doesn't change pod log behavior (no reduction in NGC/
# manifest-lookup log lines), this image likely isn't nim_llm_sdk-based —
# inspect it directly (throwaway pod, command overridden, find+cat the real
# entrypoint script) the same way insurguard's was, rather than assuming.
#
# Creates one short-lived, read-only debug pod that mounts the existing PVCs
# (no write access requested), and deletes it when done. Does not touch the
# Deployments, install anything, or need ngcApiKey — it only reads what's
# already on disk.
#
# Usage: ./discover-airgap-info.sh <namespace>

set -euo pipefail

NAMESPACE="${1:?Usage: $0 <namespace>}"
LABEL_SELECTOR="app.kubernetes.io/part-of=fraud-detection"
DEBUG_POD="fraud-detection-airgap-discovery"

command -v oc >/dev/null 2>&1 || { echo "oc CLI not found on PATH" >&2; exit 1; }

echo "== Discovering this release's PVCs in namespace '$NAMESPACE' =="
mapfile -t PVCS < <(oc get pvc -n "$NAMESPACE" -l "$LABEL_SELECTOR" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
if [ "${#PVCS[@]}" -eq 0 ]; then
  echo "No PVCs found with label $LABEL_SELECTOR in $NAMESPACE — is the release installed there?" >&2
  exit 1
fi
printf ' - %s\n' "${PVCS[@]}"

VOLUMES_YAML=""
MOUNTS_YAML=""
FOUND=()
for pvc in "${PVCS[@]}"; do
  case "$pvc" in
    nim-cache|nim-hf-cache)
      FOUND+=("$pvc")
      vol="vol-$pvc"
      VOLUMES_YAML+="  - name: $vol
    persistentVolumeClaim:
      claimName: $pvc
      readOnly: true
"
      MOUNTS_YAML+="        - name: $vol
          mountPath: /mnt/$pvc
          readOnly: true
"
      ;;
  esac
done
if [ "${#FOUND[@]}" -eq 0 ]; then
  echo "Neither nim-cache nor nim-hf-cache PVCs were found — did you upgrade to the version of this chart with PVC-backed nim-llm caching yet?" >&2
  exit 1
fi

echo
echo "== Launching read-only debug pod '$DEBUG_POD' =="
cat <<EOF | oc apply -n "$NAMESPACE" -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $DEBUG_POD
  labels:
    app: $DEBUG_POD
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: discover
      image: registry.access.redhat.com/ubi9/ubi-minimal:latest
      command: ["sleep", "600"]
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
      volumeMounts:
$MOUNTS_YAML
  volumes:
$VOLUMES_YAML
EOF

cleanup() {
  echo
  echo "== Cleaning up debug pod =="
  oc delete pod "$DEBUG_POD" -n "$NAMESPACE" --ignore-not-found=true >/dev/null
}
trap cleanup EXIT

echo "Waiting for it to be ready..."
oc wait --for=condition=Ready "pod/$DEBUG_POD" -n "$NAMESPACE" --timeout=120s

echo
echo "== localModelPath candidates (HF-hub-style snapshot dirs) =="
for pvc in "${FOUND[@]}"; do
  echo "--- $pvc (mounted at /mnt/$pvc) ---"
  oc exec -n "$NAMESPACE" "$DEBUG_POD" -- sh -c \
    "find /mnt/$pvc -path '*/snapshots/*' -maxdepth 6 -type d 2>/dev/null | grep -E '/snapshots/[^/]+\$' || echo '  (no HF-hub-style snapshot dir found, or cache is still empty — inspect manually: oc exec $DEBUG_POD -n $NAMESPACE -- find /mnt/$pvc -maxdepth 6)'"
done

echo
echo "== Next steps =="
cat <<'EOF'
1. Take a snapshot path above, prefix with the in-container mount point
   (/tmp/nim-cache or /tmp/hf-cache — see NIM_CACHE_PATH/HF_HOME in
   templates/nim-llm.yaml), and set:
     --set nimLlm.localModelPath=<path>

2. If both PVCs come back empty, nim-llm has never run against this cache —
   do a one-time bootstrap install with ngcApiKey set to populate it, then
   re-run this script.

3. Watch the resulting pod's logs after setting localModelPath. If you see
   NGC/manifest-lookup log lines (profile selection, "Detected N compatible
   profile(s)") rather than a clean straight-to-local-path load, this
   image's NIM_MODEL_NAME support is unconfirmed for real (see the caveat at
   the top of this script) — the custom cisco_fraud_detection:nim_llm tag
   may not be nim_llm_sdk-based at all. Inspect it directly:
     oc run fd-inspect -n $1 --image=<nimLLM image from values.yaml> \
       --restart=Never --command -- sleep 3600
     oc exec -n $1 fd-inspect -- sh -c "find / -maxdepth 4 -iname 'start*.sh' -o -maxdepth 4 -iname 'entrypoint*' 2>/dev/null"
     # then cat whatever turns up, same method used for insurguard's llama-parser
     oc delete pod fd-inspect -n $1
EOF
