#!/usr/bin/env bash
# ==============================================================================
# Phase 3 - Step 1: 01-prereq-wlm-iam.sh
# Configures Google Cloud Workload Manager & OpenShift Telemetry Prerequisites:
#   1. Enables workloadmanager.googleapis.com, compute.googleapis.com, and
#      logging.googleapis.com on ${PROJECT_ID}
#   2. Creates dedicated GCP Service Account:
#      ${PREFIX}-wlm-telemetry-sa@${PROJECT_ID}.iam.gserviceaccount.com
#   3. Grants minimum required IAM roles:
#      - roles/compute.viewer
#      - roles/workloadmanager.insightWriter
#      - roles/logging.logWriter
#   4. Creates the Kubernetes Secret 'telemetry-agent-sa' in 'openshift-operators'
#      with key 'workload_agent_sa_key.json'
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

WLM_SA_NAME="${PREFIX}-wlm-telemetry-sa"
WLM_SA_EMAIL="${WLM_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
TMP_KEY_FILE="$(mktemp /tmp/wlm-sa-key.XXXXXX.json)"
trap 'rm -f "${TMP_KEY_FILE}"' EXIT

echo "=============================================================================="
echo " Phase 3 Step 1: Configuring Workload Manager & Telemetry Prerequisites"
echo "   Project ID      : ${PROJECT_ID}"
echo "   Service Account : ${WLM_SA_EMAIL}"
echo "   K8s Secret      : telemetry-agent-sa (namespace: openshift-operators)"
echo "=============================================================================="

# 1. Enable required Google Cloud APIs
echo "--- 1. Enabling Workload Manager, Compute Engine & Cloud Logging APIs ---"
gcloud services enable \
  workloadmanager.googleapis.com \
  compute.googleapis.com \
  logging.googleapis.com \
  --project="${PROJECT_ID}"

# 2. Create dedicated Service Account for OpenShift Telemetry Operator
echo "--- 2. Ensuring Service Account ${WLM_SA_EMAIL} exists ---"
if gcloud iam service-accounts describe "${WLM_SA_EMAIL}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "[SKIP] Service Account '${WLM_SA_EMAIL}' already exists."
else
  gcloud iam service-accounts create "${WLM_SA_NAME}" \
    --description="Service account for Cluster Services for OpenShift Telemetry Operator (${PREFIX})" \
    --display-name="${WLM_SA_NAME}" \
    --project="${PROJECT_ID}"
  echo "[CREATED] Service Account '${WLM_SA_EMAIL}'."
  sleep 5
fi

# 3. Grant required IAM roles
echo "--- 3. Granting IAM roles (compute.viewer, workloadmanager.insightWriter, logging.logWriter) ---"
WLM_ROLES=(
  "roles/compute.viewer"
  "roles/workloadmanager.insightWriter"
  "roles/logging.logWriter"
)

for role in "${WLM_ROLES[@]}"; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${WLM_SA_EMAIL}" \
    --role="${role}" \
    --condition=None \
    --quiet >/dev/null
  echo "  [GRANTED] ${role} -> ${WLM_SA_EMAIL}"
done

# 4. Create Service Account Key & Kubernetes Secret in openshift-operators
echo "--- 4. Creating Kubernetes Secret 'telemetry-agent-sa' in openshift-operators ---"
if oc get secret telemetry-agent-sa -n openshift-operators >/dev/null 2>&1; then
  echo "[SKIP] Secret 'telemetry-agent-sa' already exists in namespace 'openshift-operators'."
  echo "       (To rotate the key, delete the secret first: oc delete secret telemetry-agent-sa -n openshift-operators)"
else
  gcloud iam service-accounts keys create "${TMP_KEY_FILE}" \
    --iam-account="${WLM_SA_EMAIL}" \
    --project="${PROJECT_ID}"

  oc create secret generic telemetry-agent-sa \
    --from-file=workload_agent_sa_key.json="${TMP_KEY_FILE}" \
    -n openshift-operators \
    --dry-run=client -o yaml | oc apply -f -
  echo "[CREATED] Secret 'telemetry-agent-sa' created in namespace 'openshift-operators'."
fi

echo ""
echo "=============================================================================="
echo " Phase 3 Prerequisites Complete!"
echo " Next Step: ./scripts/02-deploy-telemetry-operator.sh"
echo "=============================================================================="
