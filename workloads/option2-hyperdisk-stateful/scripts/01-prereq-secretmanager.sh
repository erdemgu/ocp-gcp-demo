#!/usr/bin/env bash
# ==============================================================================
# Option 2 - Step 1: 01-prereq-secretmanager.sh
# Configures Google Cloud Secret Manager for the Cymbal Stateful Workload:
#   1. Enables secretmanager.googleapis.com on ${PROJECT_ID}
#   2. Grants roles/secretmanager.admin & roles/secretmanager.secretAccessor
#      to ${SA_EMAIL}
#   3. Creates two secrets in Google Cloud Secret Manager:
#      - ${PREFIX}-cymbal-db-password
#      - ${PREFIX}-cymbal-api-key
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${HOME}/ocp-setup/config.env" ]]; then
  # shellcheck source=/dev/null
  source "${HOME}/ocp-setup/config.env"
elif [[ -f "${SCRIPT_DIR}/../../../config.env" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/../../../config.env"
else
  echo "ERROR: config.env not found."
  exit 1
fi

DB_SECRET_NAME="${PREFIX}-cymbal-db-password"
API_SECRET_NAME="${PREFIX}-cymbal-api-key"

echo "=============================================================================="
echo " Option 2 Step 1: Configuring Google Cloud Secret Manager"
echo "   Project ID : ${PROJECT_ID}"
echo "   Secrets    : ${DB_SECRET_NAME}, ${API_SECRET_NAME}"
echo "=============================================================================="

# 1. Enable Secret Manager API
echo "--- 1. Enabling secretmanager.googleapis.com ---"
gcloud services enable secretmanager.googleapis.com --project="${PROJECT_ID}"

# 2. Grant Secret Manager IAM roles to OCP Service Account
echo "--- 2. Granting Secret Manager IAM roles to ${SA_EMAIL} ---"
for role in "roles/secretmanager.admin" "roles/secretmanager.secretAccessor"; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="${role}" \
    --condition=None \
    --quiet >/dev/null
done

# Helper to create or update secret in Secret Manager
ensure_secret() {
  local sec_name="$1"
  local sec_val="$2"
  if gcloud secrets describe "${sec_name}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    echo "[SKIP] Secret '${sec_name}' already exists in Secret Manager."
  else
    printf "%s" "${sec_val}" | gcloud secrets create "${sec_name}" \
      --replication-policy="automatic" \
      --data-file=- \
      --project="${PROJECT_ID}"
    echo "[CREATED] Secret '${sec_name}' created in Google Cloud Secret Manager."
  fi
}

echo "--- 3. Creating Cymbal Secrets in Google Cloud Secret Manager ---"
ensure_secret "${DB_SECRET_NAME}" "CymbalHyperdiskPg2026!"
ensure_secret "${API_SECRET_NAME}" "cymbal-live-sec-$(openssl rand -hex 8)"

echo ""
echo "=============================================================================="
echo " Google Cloud Secret Manager Prerequisites Complete!"
echo " Next Step: ./scripts/02-deploy-secrets-csi.sh"
echo "=============================================================================="
