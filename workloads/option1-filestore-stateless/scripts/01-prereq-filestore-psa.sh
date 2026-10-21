#!/usr/bin/env bash
# ==============================================================================
# Option 1 - Step 1: 01-prereq-filestore-psa.sh
# Configures all Google Cloud & OpenShift prerequisites for Regional Private
# Cloud Filestore:
#   1. Enables file.googleapis.com and servicenetworking.googleapis.com
#   2. Grants roles/file.editor & roles/servicenetworking.networksAdmin to OCP SA
#   3. Reserves /20 Private Service Access (PSA) IP range (${PREFIX}-psa-range)
#   4. Connects VPC Peering to servicenetworking.googleapis.com
#   5. Creates gcp-filestore-cloud-credentials secret in openshift-cluster-csi-drivers
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${HOME}/ocp-setup/config.env" ]]; then
  # shellcheck source=/dev/null
  source "${HOME}/ocp-setup/config.env"
  SA_KEY_PATH="${HOME}/ocp-setup/${PREFIX}-sa-key.json"
elif [[ -f "${SCRIPT_DIR}/../../../config.env" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/../../../config.env"
  SA_KEY_PATH="${SA_KEY_FILE}"
else
  echo "ERROR: config.env not found in ~/ocp-setup/ or repository root."
  exit 1
fi

export PATH="${HOME}/bin:${PATH}"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"

PSA_RANGE_NAME="${PREFIX}-psa-range"

echo "=============================================================================="
echo " Option 1 (Filestore) Step 1: Configuring Cloud Filestore & Private Service Access"
echo "   Project ID : ${PROJECT_ID}"
echo "   VPC        : ${VPC_NAME}"
echo "   PSA Range  : ${PSA_RANGE_NAME} (/20)"
echo "=============================================================================="

# 1. Enable Cloud Filestore & Service Networking APIs
echo "--- 1. Enabling file.googleapis.com and servicenetworking.googleapis.com ---"
gcloud services enable file.googleapis.com servicenetworking.googleapis.com \
  --project="${PROJECT_ID}"

# 2. Grant Filestore & Service Networking IAM roles to OCP Service Account
echo "--- 2. Granting Filestore & Service Networking IAM roles to ${SA_EMAIL} ---"
for role in "roles/file.editor" "roles/servicenetworking.networksAdmin"; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="${role}" \
    --condition=None \
    --quiet >/dev/null
done

# 3. Allocate Private Service Access (PSA) IP range in VPC
echo "--- 3. Allocating Private Service Access IP range (${PSA_RANGE_NAME}) ---"
if gcloud compute addresses describe "${PSA_RANGE_NAME}" \
    --global --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "[SKIP] PSA IP range '${PSA_RANGE_NAME}' already exists."
else
  gcloud compute addresses create "${PSA_RANGE_NAME}" \
    --global \
    --purpose=VPC_PEERING \
    --prefix-length=20 \
    --description="Private Service Access peering range for Cloud Filestore (${PREFIX})" \
    --network="${VPC_NAME}" \
    --project="${PROJECT_ID}"
  echo "[CREATED] Allocated /20 PSA range '${PSA_RANGE_NAME}'."
fi

# 4. Connect Service Networking VPC Peering
echo "--- 4. Connecting VPC Peering to servicenetworking.googleapis.com ---"
if gcloud services vpc-peerings list \
    --network="${VPC_NAME}" --project="${PROJECT_ID}" 2>/dev/null | grep -q "servicenetworking-googleapis-com"; then
  echo "[UPDATE] Updating existing servicenetworking VPC peering with range '${PSA_RANGE_NAME}'..."
  gcloud services vpc-peerings update \
    --service=servicenetworking.googleapis.com \
    --ranges="${PSA_RANGE_NAME}" \
    --network="${VPC_NAME}" \
    --project="${PROJECT_ID}" \
    --force || true
else
  echo "[CREATE] Creating servicenetworking VPC peering connection..."
  gcloud services vpc-peerings connect \
    --service=servicenetworking.googleapis.com \
    --ranges="${PSA_RANGE_NAME}" \
    --network="${VPC_NAME}" \
    --project="${PROJECT_ID}"
fi

# Note: gcp-filestore-cloud-credentials in openshift-cluster-csi-drivers is
# automatically minted and managed by OpenShift's Cloud Credential Operator (CCO)
# when the GCP Filestore CSI Driver Operator is installed in Step 2.

echo ""
echo "=============================================================================="
echo " Filestore & Private Service Access Prerequisites Complete!"
echo " Next Step: ./scripts/02-deploy-filestore-csi.sh"
echo "=============================================================================="
