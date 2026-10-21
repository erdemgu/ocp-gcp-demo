#!/usr/bin/env bash
# ==============================================================================
# Phase 3 - Step 3: 03-trigger-and-verify.sh
# Verifies the Cluster Services for OpenShift Telemetry Operator and triggers
# an immediate on-demand telemetry collection run:
#   1. Checks CSV, TelemetryConfig CR, and workloadagent-operator pod status
#   2. Triggers immediate metrics collection via /openshift-docker-entrypoint.sh
#      (so you do not have to wait for the default 30-minute interval)
#   3. Queries Google Cloud Logging for 'google-cloud-workload-agent' entries
#   4. Prints Google Cloud Console links for Workload Manager Evaluation
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${HOME}/ocp-setup/config.env" ]]; then
  # shellcheck source=/dev/null
  source "${HOME}/ocp-setup/config.env"
elif [[ -f "${SCRIPT_DIR}/../../config.env" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/../../config.env"
else
  echo "ERROR: config.env not found in ~/ocp-setup/ or repository root."
  exit 1
fi

export PATH="${HOME}/bin:${PATH}"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"

echo "=============================================================================="
echo " Phase 3 Step 3: Verifying Telemetry Operator & Triggering Metrics Collection"
echo "   Project ID : ${PROJECT_ID}"
echo "   Cluster    : ${CLUSTER_NAME}.${BASE_DOMAIN}"
echo "=============================================================================="

# 0. Ensure TelemetryConfig has imageVersion set (required by operator controller v0.0.7+)
IMG_VER="$(oc get telemetryconfig telemetryconfig -n openshift-operators -o jsonpath='{.spec.imageVersion}' 2>/dev/null || true)"
if [[ -z "${IMG_VER}" ]]; then
  echo "[FIX] TelemetryConfig 'telemetryconfig' is missing spec.imageVersion; recreating cleanly with imageVersion='latest'..."
  oc delete telemetryconfig telemetryconfig -n openshift-operators --ignore-not-found
  oc apply -f "${SCRIPT_DIR}/../manifests/02-telemetry-config.yaml"
fi

# 1. Verify Operator Pod Status
echo "--- 1. Waiting for workloadagent-operator pod to be Running ---"
POD_NAME=""
for ((i=1; i<=24; i++)); do
  POD_NAME="$(oc get pods -n openshift-operators \
    -l app.kubernetes.io/name=workloadagent-operator \
    --field-selector=status.phase=Running \
    -o=name 2>/dev/null | head -n 1 || true)"
  if [[ -n "${POD_NAME}" ]]; then
    echo "[READY] Found running telemetry operator pod: ${POD_NAME}"
    break
  fi
  echo "  Waiting for workloadagent-operator pod (attempt ${i}/24)..."
  sleep 5
done

if [[ -z "${POD_NAME}" ]]; then
  echo "ERROR: No running pod found with label app.kubernetes.io/name=workloadagent-operator in openshift-operators."
  oc get pods -n openshift-operators
  exit 1
fi

oc get pods -n openshift-operators -l app.kubernetes.io/name=workloadagent-operator -o wide
echo ""
echo "--- 2. TelemetryConfig Status ---"
oc get telemetryconfig telemetryconfig -n openshift-operators -o yaml | grep -A 25 "^spec:" || true

# 2. Verify WLM transmission (and optionally trigger a fresh collection if --trigger is passed)
echo ""
echo "--- 3. Verifying OpenShift Metrics Collection & WLM Transmission ---"
if [[ "${1:-}" == "--trigger" ]]; then
  echo "Triggering immediate on-demand collection by recreating the telemetryconfig pod..."
  echo "(Note: We delete the pod rather than 'oc rollout restart' because the operator controller"
  echo " reconciles the Deployment spec every 60s and would revert rollout annotations.)"
  oc delete pod -n openshift-operators -l app.kubernetes.io/name=workloadagent-operator --wait=true
  sleep 5
fi

echo "Checking pod logs for OpenShiftMetricCollection -> Workload Manager (takes ~90s on a new pod)..."
SENT_OK="false"
for ((i=1; i<=30; i++)); do
  POD_NAME="$(oc get pods -n openshift-operators \
    -l app.kubernetes.io/name=workloadagent-operator \
    --field-selector=status.phase=Running \
    -o=name 2>/dev/null | head -n 1 || true)"

  if [[ -n "${POD_NAME}" ]] && oc logs -n openshift-operators "${POD_NAME}" 2>/dev/null | grep -q "Metrics successfully sent to WLM"; then
    echo "[SUCCESS] OpenShift cluster metrics collected and sent to Google Cloud Workload Manager (${POD_NAME})!"
    oc logs -n openshift-operators "${POD_NAME}" 2>/dev/null | grep -E "Starting OpenShift Metric Collection|WriteInsight response|Metrics successfully sent to WLM" | tail -n 6
    SENT_OK="true"
    break
  fi
  echo "  Waiting for metric collection to complete on ${POD_NAME:-pending-pod} (attempt ${i}/30)..."
  sleep 5
done

if [[ "${SENT_OK}" != "true" ]]; then
  echo "[WARN] Did not yet see 'Metrics successfully sent to WLM' in pod logs; recent logs:"
  if [[ -n "${POD_NAME:-}" ]]; then
    oc logs -n openshift-operators "${POD_NAME}" --tail=15 || true
  fi
fi

# 3. Check Cloud Logging for google-cloud-workload-agent logs
echo ""
echo "--- 4. Checking Google Cloud Logging (google-cloud-workload-agent) ---"
sleep 5
LOG_ENTRIES="$(gcloud logging read "logName=\"projects/${PROJECT_ID}/logs/google-cloud-workload-agent\"" \
  --project="${PROJECT_ID}" \
  --limit=5 \
  --format="table(timestamp, severity, jsonPayload.message, textPayload)" 2>/dev/null || true)"

if [[ -n "${LOG_ENTRIES}" ]]; then
  echo "${LOG_ENTRIES}"
else
  echo "  [INFO] No Cloud Logging entries returned yet (logs may take 1-2 minutes to index)."
fi

echo ""
echo "=============================================================================="
echo " Telemetry Collection Triggered Successfully!"
echo "=============================================================================="
echo " View Operator Logs in Cloud Logging:"
echo "   https://console.cloud.google.com/logs/query;query=logName%3D%22projects%2F${PROJECT_ID}%2Flogs%2Fgoogle-cloud-workload-agent%22?project=${PROJECT_ID}"
echo ""
echo " Create & Run an OpenShift Evaluation in Google Cloud Workload Manager:"
echo "   https://console.cloud.google.com/workload-manager/evaluations?project=${PROJECT_ID}"
echo "=============================================================================="
