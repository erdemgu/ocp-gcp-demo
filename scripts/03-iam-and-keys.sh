#!/usr/bin/env bash
# ==============================================================================
# 03-iam-and-keys.sh
# 1. Generates SSH key pair required for OpenShift installation
# 2. Creates OpenShift GCP Service Account (${PREFIX}-ocp-sa)
# 3. Grants required IAM roles on the project
# 4. Generates the Service Account JSON key file (${PREFIX}-sa-key.json)
# ==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ ! -f "${REPO_ROOT}/config.env" ]]; then
  echo "ERROR: config.env not found. Please run ./scripts/00-prereq-config.sh first."
  exit 1
fi
# shellcheck source=/dev/null
source "${REPO_ROOT}/config.env"

mkdir -p "${REPO_ROOT}/generated"

echo "=============================================================================="
echo " Step 1: Generating SSH Key Pair for OpenShift Installation"
echo " Key Path: ${SSH_KEY_FILE}"
echo "=============================================================================="
if [[ -f "${SSH_KEY_FILE}" && -f "${SSH_KEY_FILE}.pub" ]]; then
  echo "[SKIP] SSH key pair already exists at ${SSH_KEY_FILE}"
else
  ssh-keygen -t ed25519 -N '' -f "${SSH_KEY_FILE}" -C "ocp-admin@${PREFIX}"
  chmod 600 "${SSH_KEY_FILE}"
  chmod 644 "${SSH_KEY_FILE}.pub"
  echo "[CREATED] SSH key pair generated at ${SSH_KEY_FILE}"
fi

echo ""
echo "=============================================================================="
echo " Step 2: Creating OpenShift Service Account"
echo " Service Account: ${SA_EMAIL}"
echo "=============================================================================="
if gcloud iam service-accounts describe "${SA_EMAIL}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "[SKIP] Service Account '${SA_EMAIL}' already exists."
else
  gcloud iam service-accounts create "${SA_NAME}" \
    --project="${PROJECT_ID}" \
    --display-name="OpenShift Installer Service Account (${PREFIX})"
  echo "[CREATED] Service Account '${SA_EMAIL}'."
  # Brief pause to allow IAM eventual consistency
  sleep 5
fi

echo ""
echo "=============================================================================="
echo " Step 3: Binding Required IAM Roles to ${SA_EMAIL}"
echo "=============================================================================="
OCP_IAM_ROLES=(
  "roles/owner"
  "roles/compute.admin"
  "roles/iam.securityAdmin"
  "roles/iam.serviceAccountAdmin"
  "roles/iam.serviceAccountUser"
  "roles/iam.serviceAccountKeyAdmin"
  "roles/iam.serviceAccountTokenCreator"
  "roles/resourcemanager.projectIamAdmin"
  "roles/storage.admin"
  "roles/dns.admin"
  "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  "roles/viewer"
  "roles/serviceusage.serviceUsageViewer"
)

for role in "${OCP_IAM_ROLES[@]}"; do
  echo "  -> Granting ${role} ..."
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="${role}" \
    --condition=None \
    --quiet >/dev/null
done

echo ""
echo "=============================================================================="
echo " Step 4: Generating Service Account JSON Key File"
echo " Key File: ${SA_KEY_FILE}"
echo "=============================================================================="
if [[ -f "${SA_KEY_FILE}" ]]; then
  echo "[SKIP] Service Account key file already exists at ${SA_KEY_FILE}"
else
  gcloud iam service-accounts keys create "${SA_KEY_FILE}" \
    --iam-account="${SA_EMAIL}" \
    --project="${PROJECT_ID}"
  chmod 600 "${SA_KEY_FILE}"
  echo "[CREATED] Service Account key saved to ${SA_KEY_FILE}"
fi

echo ""
echo "=============================================================================="
echo " SSH Key and OCP Service Account Key Ready!"
echo "   SSH Private Key : ${SSH_KEY_FILE}"
echo "   SSH Public Key  : ${SSH_KEY_FILE}.pub"
echo "   SA JSON Key     : ${SA_KEY_FILE}"
echo "=============================================================================="
echo "Next step: Run ./scripts/04-bastion-setup.sh"
