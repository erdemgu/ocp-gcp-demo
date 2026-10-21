#!/usr/bin/env bash
# ==============================================================================
# 01-policy-check.sh
# Checks and configures GCP Organization Policies and enables required APIs:
#   1. Service Account & Key Creation (Legacy & Managed constraints):
#      - iam.disableServiceAccountKeyCreation
#      - iam.managed.disableServiceAccountKeyCreation
#      - iam.disableServiceAccountCreation
#      - iam.managed.disableServiceAccountCreation
#   2. compute.trustedImageProjects (projects/debian-cloud, projects/rhel-cloud,
#      projects/rhcos-cloud, projects/redhat-marketplace-public, projects/mpi-redhat-marketplace-public)
# ==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ ! -f "${REPO_ROOT}/config.env" ]]; then
  echo "ERROR: config.env not found. Please run ./scripts/00-prereq-config.sh first."
  exit 1
fi
# shellcheck source=/dev/null
source "${REPO_ROOT}/config.env"

echo "=============================================================================="
echo " Step 1: Setting active project and enabling required Google Cloud APIs"
echo " Project: ${PROJECT_ID}"
echo "=============================================================================="
gcloud config set project "${PROJECT_ID}"

REQUIRED_APIS=(
  "orgpolicy.googleapis.com"
  "compute.googleapis.com"
  "dns.googleapis.com"
  "iam.googleapis.com"
  "iamcredentials.googleapis.com"
  "cloudresourcemanager.googleapis.com"
  "serviceusage.googleapis.com"
  "deploymentmanager.googleapis.com"
  "storage-api.googleapis.com"
  "storage-component.googleapis.com"
)

echo "Enabling APIs: ${REQUIRED_APIS[*]} ..."
gcloud services enable "${REQUIRED_APIS[@]}" --project="${PROJECT_ID}"

mkdir -p "${REPO_ROOT}/generated/policies"

echo ""
echo "=============================================================================="
echo " Step 2: Policy Check #1 - Service Account & Key Creation (Legacy & Managed)"
echo " Constraints:"
echo "   - constraints/iam.disableServiceAccountKeyCreation"
echo "   - constraints/iam.managed.disableServiceAccountKeyCreation"
echo "   - constraints/iam.disableServiceAccountCreation"
echo "   - constraints/iam.managed.disableServiceAccountCreation"
echo "=============================================================================="
SA_CONSTRAINTS=(
  "iam.disableServiceAccountKeyCreation"
  "iam.managed.disableServiceAccountKeyCreation"
  "iam.disableServiceAccountCreation"
  "iam.managed.disableServiceAccountCreation"
)

for constraint in "${SA_CONSTRAINTS[@]}"; do
  echo "--- Checking ${constraint} ---"
  gcloud org-policies describe "${constraint}" \
    --project="${PROJECT_ID}" --effective || true

  POLICY_FILE="${REPO_ROOT}/generated/policies/${constraint}.yaml"
  cat <<EOF > "${POLICY_FILE}"
name: projects/${PROJECT_ID}/policies/${constraint}
spec:
  rules:
  - enforce: false
EOF

  echo "Applying policy override (enforce: false) for ${constraint} on project ${PROJECT_ID}..."
  gcloud org-policies set-policy "${POLICY_FILE}" --project="${PROJECT_ID}" || \
    echo "[WARN] Could not set ${constraint} (constraint may not exist in this org); continuing."
done

echo ""
echo "=============================================================================="
echo " Step 3: Policy Check #2 - Trusted Image Projects"
echo " Constraint: constraints/compute.trustedImageProjects"
echo " Checking: projects/debian-cloud, projects/rhel-cloud, projects/rhcos-cloud, projects/redhat-marketplace-public, projects/mpi-redhat-marketplace-public"
echo "=============================================================================="
EFFECTIVE_IMAGES="$(gcloud org-policies describe compute.trustedImageProjects \
  --project="${PROJECT_ID}" --effective --format="yaml" 2>/dev/null || true)"

if echo "${EFFECTIVE_IMAGES}" | grep -q "projects/debian-cloud" && \
   echo "${EFFECTIVE_IMAGES}" | grep -q "projects/rhel-cloud" && \
   echo "${EFFECTIVE_IMAGES}" | grep -q "projects/rhcos-cloud" && \
   echo "${EFFECTIVE_IMAGES}" | grep -q "projects/redhat-marketplace-public" && \
   echo "${EFFECTIVE_IMAGES}" | grep -q "projects/mpi-redhat-marketplace-public"; then
  echo "[OK] projects/debian-cloud, projects/rhel-cloud, projects/rhcos-cloud, projects/redhat-marketplace-public, and projects/mpi-redhat-marketplace-public are already allowed."
else
  TRUSTED_IMAGES_FILE="${REPO_ROOT}/generated/policies/trusted-images.yaml"
  cat <<EOF > "${TRUSTED_IMAGES_FILE}"
name: projects/${PROJECT_ID}/policies/compute.trustedImageProjects
spec:
  inheritFromParent: true
  rules:
  - values:
      allowedValues:
      - projects/debian-cloud
      - projects/rhel-cloud
      - projects/rhcos-cloud
      - projects/redhat-marketplace-public
      - projects/mpi-redhat-marketplace-public
EOF

  echo "Applying trusted image policy (projects/debian-cloud, projects/rhel-cloud, projects/rhcos-cloud, projects/redhat-marketplace-public, projects/mpi-redhat-marketplace-public)..."
  gcloud org-policies set-policy "${TRUSTED_IMAGES_FILE}" --project="${PROJECT_ID}"
fi

echo ""
echo "=============================================================================="
echo " Verification Summary of Organization Policies on ${PROJECT_ID}"
echo "=============================================================================="
for policy in \
  iam.disableServiceAccountKeyCreation \
  iam.managed.disableServiceAccountKeyCreation \
  iam.disableServiceAccountCreation \
  iam.managed.disableServiceAccountCreation \
  compute.trustedImageProjects; do
  echo "--- Policy: ${policy} ---"
  gcloud org-policies describe "${policy}" --project="${PROJECT_ID}" --effective || true
done

echo ""
echo "Wait ~30-60 seconds for Organization Policy changes to propagate before creating keys."
echo "Next step: Run ./scripts/02-vpc-setup.sh"
