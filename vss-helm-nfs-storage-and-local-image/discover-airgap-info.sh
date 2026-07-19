#!/usr/bin/env bash
# Read-only discovery helper for making this chart's NIM/VLM/CV components
# air-gapped — adapted from the equivalent script in the insurguard chart.
#
# Two things this chart still needs that couldn't be determined without live
# cluster/image access (none was available while writing this):
#
#   1. nim-llm's real local snapshot path, for nimLlm.localModelPath — same
#      idea as insurguard's llamaParser.localModelPath, mechanism already
#      wired into templates/deployment-nim-llm.yaml, just needs the real path.
#   2. Whether via-server's MODEL_PATH (currently
#      "git:https://huggingface.co/Qwen/Qwen3-VL-8B-Instruct" — a live git
#      clone at deploy time) accepts a local filesystem path instead of a
#      git URL, and whether nv-cv-event-detector's start_nv_cv_event_detector.sh
#      unconditionally needs NGC or checks its cache PVCs first. Both require
#      reading the actual entrypoint/bootstrap script out of a running pod —
#      exactly how insurguard's nim_llm_sdk.hub.ngc_injector.inject_ngc_hub
#      bypass was found and confirmed. DO NOT guess at a fix for either of
#      these without doing that — the insurguard nvclip investigation found
#      real, non-obvious surprises this same way (a Python-backend Triton
#      model expecting raw bytes, not a preprocessed tensor).
#
# Creates one short-lived, read-only debug pod that mounts the existing PVCs
# (no write access requested), and deletes it when done. Also offers to spin
# up throwaway inspection pods using the actual via-server/cv-event-detector
# images (command overridden, so nothing starts for real) to read their
# bootstrap scripts.
#
# Usage: ./discover-airgap-info.sh <namespace> <release-name>

set -euo pipefail

NAMESPACE="${1:?Usage: $0 <namespace> <release-name>}"
RELEASE="${2:?Usage: $0 <namespace> <release-name>}"
DEBUG_POD="${RELEASE}-airgap-discovery"

command -v oc >/dev/null 2>&1 || { echo "oc CLI not found on PATH" >&2; exit 1; }

PVC_NAMES=("${RELEASE}-nim-model-cache" "${RELEASE}-via-ngc-model-cache" "${RELEASE}-via-hf-cache")

echo "== Checking which of the expected PVCs exist in namespace '$NAMESPACE' =="
VOLUMES_YAML=""
MOUNTS_YAML=""
FOUND=()
for pvc in "${PVC_NAMES[@]}"; do
  if oc get pvc "$pvc" -n "$NAMESPACE" >/dev/null 2>&1; then
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
  fi
done
if [ "${#FOUND[@]}" -eq 0 ]; then
  echo "None of the expected PVCs found in $NAMESPACE for release '$RELEASE' — is it installed there?" >&2
  exit 1
fi
printf ' - %s\n' "${FOUND[@]}"

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
echo "== 1. nim-llm localModelPath candidates (HF-hub-style snapshot dirs) =="
if [ -d "/mnt/${RELEASE}-nim-model-cache" ] || oc get pvc "${RELEASE}-nim-model-cache" -n "$NAMESPACE" >/dev/null 2>&1; then
  oc exec -n "$NAMESPACE" "$DEBUG_POD" -- sh -c \
    "find /mnt/${RELEASE}-nim-model-cache -path '*/snapshots/*' -maxdepth 6 -type d 2>/dev/null | grep -E '/snapshots/[^/]+\$' || echo '  (no HF-hub-style snapshot dir found — inspect manually, or this cache is still empty)'"
fi

echo
echo "== 2. via-ngc-model-cache / via-hf-cache contents (informs the via-server/cv-event-detector question) =="
for pvc in "${RELEASE}-via-ngc-model-cache" "${RELEASE}-via-hf-cache"; do
  echo "--- $pvc ---"
  oc exec -n "$NAMESPACE" "$DEBUG_POD" -- sh -c \
    "find /mnt/$pvc -mindepth 1 -maxdepth 3 2>/dev/null || echo '  (empty or not mounted)'"
done

echo
echo "== Next steps (require live image inspection — do not skip) =="
cat <<EOF
1. nim-llm: take a snapshot path from section 1, prefix with the in-container
   mount point (nimLlm.modelDirectory, default /models), and set:
     --set nimLlm.localModelPath=<path>

2. via-server's MODEL_PATH / cv-event-detector's NGC dependency: inspect the
   real images the same way insurguard's llama-parser/nvclip were inspected —
   spin up a throwaway pod with the command overridden, then read the actual
   bootstrap script:

     oc run vss-inspect -n $NAMESPACE --image=<viaServer.image from values.yaml> \\
       --restart=Never --command -- sleep 3600
     oc wait -n $NAMESPACE --for=condition=Ready pod/vss-inspect --timeout=180s
     oc exec -n $NAMESPACE vss-inspect -- sh -c "find / -maxdepth 4 -iname 'start*.sh' -o -maxdepth 4 -iname 'entrypoint*' 2>/dev/null"
     # then cat whatever that turns up, and look specifically for how
     # MODEL_PATH is parsed (does it special-case a "git:" prefix and treat
     # anything else as a local path? that's the answer we need)
     oc delete pod vss-inspect -n $NAMESPACE

   Repeat against cvEventDetector.image, reading
   /opt/nvidia/nv-cv-event-detector/start_nv_cv_event_detector.sh directly
   (its path is already known from deployment-nv-cv-event-detector.yaml) —
   look for whether it checks the ngc-model-cache PVC before ever
   constructing an NGC API call, or always calls out regardless.

3. Only after reading those real scripts, decide: does MODEL_PATH accept a
   local directory (cheap fix, same as llama-parser), or does via-server need
   an nvclip-style full bypass? Does cv-event-detector already work fine from
   a warm cache with zero credentials (nothing to fix), or does it need NGC
   access at least once to ever populate that cache (same bootstrap-then-
   discover flow used everywhere else in this effort)?
EOF
