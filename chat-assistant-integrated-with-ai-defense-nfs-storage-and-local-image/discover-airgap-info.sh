#!/usr/bin/env bash
# Read-only discovery helper for making this chart's NIMs air-gapped —
# adapted from the equivalent script in the insurguard chart.
#
# Unlike insurguard, this chart's resources carry no unique
# app.kubernetes.io/part-of label, so PVCs are matched here by their known,
# fixed names instead of a label selector.
#
# Answers:
#   1. The real modelProfile-equivalent value for llama/content/topicControl/
#      embedqa — read the cached snapshot directory name straight off each
#      nim-cache PVC (no NIM/NGC involvement, just a directory listing), for
#      use as nvidia.<name>LocalModelPath.
#   2. Whether embedqa's cache looks like the others (an
#      nim_llm_sdk-style HF-hub snapshot layout) or something else entirely
#      (e.g. a Triton model repository, like insurguard's nvclip) — that
#      tells us which bypass mechanism actually applies to it.
#
# Creates one short-lived, read-only debug pod that mounts the existing PVCs
# (no write access requested), and deletes it when done. Does not touch the
# Deployments, install anything, or need ngc.apiKey — it only reads what's
# already on disk.
#
# Usage: ./discover-airgap-info.sh <namespace>   (default namespace: chat-assistant)

set -euo pipefail

NAMESPACE="${1:-chat-assistant}"
DEBUG_POD="chat-assistant-airgap-discovery"
PVC_NAMES=(nim-cache-llama nim-cache-content nim-cache-topic-control nim-cache-embedqa rails-hf-cache)

command -v oc >/dev/null 2>&1 || { echo "oc CLI not found on PATH" >&2; exit 1; }

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
  echo "None of the expected PVCs (${PVC_NAMES[*]}) exist in $NAMESPACE — is the release installed there?" >&2
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
echo "== 1. localModelPath candidates (HF-hub-style snapshot dirs) under each cache =="
for pvc in "${FOUND[@]}"; do
  echo "--- $pvc (mounted at /mnt/$pvc) ---"
  oc exec -n "$NAMESPACE" "$DEBUG_POD" -- sh -c \
    "find /mnt/$pvc -path '*/snapshots/*' -mindepth 0 -maxdepth 6 -type d 2>/dev/null | grep -E '/snapshots/[^/]+$' || echo '  (no HF-hub-style snapshot dir found — inspect manually: oc exec $DEBUG_POD -n $NAMESPACE -- find /mnt/$pvc -maxdepth 6)'"
done

echo
echo "== 2. embedqa cache layout sanity check (Triton repo vs. HF-hub snapshot vs. empty) =="
if oc get pvc nim-cache-embedqa -n "$NAMESPACE" >/dev/null 2>&1; then
  oc exec -n "$NAMESPACE" "$DEBUG_POD" -- sh -c \
    "find /mnt/nim-cache-embedqa -mindepth 1 -maxdepth 2 2>/dev/null || echo '  (empty — embedqa has never been run against this cache yet)'"
else
  echo "  nim-cache-embedqa PVC doesn't exist yet — will be created on next helm upgrade."
fi

echo
echo "== Next steps =="
cat <<'EOF'
1. Take the snapshot paths from section 1, prefix with /opt/nim/.cache/ (the
   in-container mount point), and set:
     --set nvidia.llamaLocalModelPath=<path> \
     --set nvidia.contentLocalModelPath=<path> \
     --set nvidia.topicControlLocalModelPath=<path> \
     --set nvidia.embedqaLocalModelPath=<path>   # only if section 2 looks HF-hub-shaped

2. If embedqa's cache (section 2) looks like a Triton model repository
   (config.pbtxt files, versioned model dirs) rather than an HF-hub snapshot
   tree, it's the insurguard nvclip case, not the llama-parser case —
   embedqaLocalModelPath won't work, and it needs the same
   airgappedTritonMode-style adapter approach instead. Report back what
   section 2 actually shows before assuming either way.

3. If any PVC came back empty in section 1, that component has never been
   run against this cache — do a one-time bootstrap install with
   ngc.apiKey set to populate it, then re-run this script.

4. As with insurguard, ngc.apiKey stays required for image pulls regardless
   (these 4 NIM images are pulled straight from nvcr.io, unmirrored) — these
   localModelPath fixes only remove the in-container runtime NGC dependency,
   not the image-pull one.
EOF
