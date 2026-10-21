#!/usr/bin/env bash
# ==============================================================================
# Phase 3 - Step 4: 04-cleanup-phase3.sh
# Removes the Cluster Services for OpenShift Telemetry Operator and resources:
#   1. Deletes TelemetryConfig 'telemetryconfig' in openshift-operators
#   2. Deletes Subscription 'google-cloud-cluster-services-for-openshift-telemetry'
#      and its ClusterServiceVersion (CSV) in openshift-operators
#   3. Deletes Secret 'telemetry-agent-sa' and Namespace 'workloadmanager'
#   4. Deletes GCP Service Account ${PREFIX}-wlm-telemetry-sa
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="${SCRIPT_DIR}/../manifests"

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

WLM_SA_NAME="${PREFIX}-wlm-telemetry-sa"
WLM_SA_EMAIL="${WLM_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "=============================================================================="
echo " Phase 3 Cleanup: Removing Telemetry Operator & Workload Manager Resources"
echo "=============================================================================="

echo "--- 1. Deleting TelemetryConfig & Production Tagging Namespace ---"
oc delete -f "${MANIFEST_DIR}/02-telemetry-config.yaml" --ignore-not-found || true
oc delete -f "${MANIFEST_DIR}/03-wlm-production-env.yaml" --ignore-not-found || true

echo "--- 2. Deleting Operator Subscription & ClusterServiceVersion ---"
oc delete -f "${MANIFEST_DIR}/01-telemetry-subscription.yaml" --ignore-not-found || true
for csv in $(oc get csv -n openshift-operators -o name 2>/dev/null | grep "cluster-services-for-openshift-telemetry" || true); do
  oc delete "${csv}" -n openshift-operators --ignore-not-found
  echo "  [DELETED] ${csv}"
done

echo "--- 3. Deleting Kubernetes Secret 'telemetry-agent-sa' ---"
oc delete secret telemetry-agent-sa -n openshift-operators --ignore-not-found

echo "--- 4. Deleting GCP Service Account (${WLM_SA_EMAIL}) ---"
if gcloud iam service-accounts describe "${WLM_SA_EMAIL}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud iam service-accounts delete "${WLM_SA_EMAIL}" --project="${PROJECT_ID}" --quiet
  echo "[DELETED] Service Account '${WLM_SA_EMAIL}'."
else
  echo "[SKIP] Service Account '${WLM_SA_EMAIL}' not found."
fi

echo ""
echo "=============================================================================="
echo " Phase 3 Cleanup Complete!"
echo "=============================================================================="
