#!/usr/bin/env bash
# ==============================================================================
# 04-bastion-setup.sh
# 1. Renders install-config.yaml keeping custom VM sizes (n4-custom-6-20480 +
#    hyperdisk-balanced for workers, e2-standard-4 + pd-ssd for control plane)
# 2. Creates the private Linux Bastion VM (${PREFIX}-bastion) in ${SUBNET_BASTION}
# 3. Waits for SSH readiness via Cloud IAP
# 4. Copies all necessary files (install-config.yaml, SA key, SSH keys, config.env,
#    and 05-bastion-install-ocp.sh) to the Bastion VM
# ==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ ! -f "${REPO_ROOT}/config.env" ]]; then
  echo "ERROR: config.env not found. Please run ./scripts/00-prereq-config.sh first."
  exit 1
fi
# shellcheck source=/dev/null
source "${REPO_ROOT}/config.env"

for required_file in "${SSH_KEY_FILE}" "${SSH_KEY_FILE}.pub" "${SA_KEY_FILE}" "${PULL_SECRET_FILE}"; do
  if [[ ! -f "${required_file}" ]]; then
    echo "ERROR: Required file '${required_file}' is missing. Did you run ./scripts/03-iam-and-keys.sh?"
    exit 1
  fi
done

echo "=============================================================================="
echo " Step 1: Generating install-config.yaml from template"
echo "=============================================================================="
PULL_SECRET_CONTENT="$(tr -d '\n\r' < "${PULL_SECRET_FILE}")"
SSH_PUB_KEY="$(tr -d '\n\r' < "${SSH_KEY_FILE}.pub")"

if [[ "${USE_MARKETPLACE_IMAGE:-false}" == "true" ]]; then
  OS_IMAGE_BLOCK="      osImage:
        project: ${MARKETPLACE_IMAGE_PROJECT:-redhat-marketplace-public}
        name: ${MARKETPLACE_IMAGE_NAME:-redhat-coreos-ocp-413-x86-64-202305021736}
"
  # The 4.13 Marketplace boot image has an older 2023 shim/GRUB EFI signature
  # that fails Secure Boot after pivoting to RHCOS 9.8 (OCP 4.22), so disable Secure Boot.
  SECURE_BOOT_MODE="Disabled"
  echo "  -> Including Google Cloud Marketplace osImage for worker and master: ${MARKETPLACE_IMAGE_PROJECT}/${MARKETPLACE_IMAGE_NAME} (secureBoot: Disabled)"
else
  OS_IMAGE_BLOCK="#      osImage:
#        project: redhat-marketplace-public
#        name: redhat-coreos-ocp-413-x86-64-202305021736
"
  SECURE_BOOT_MODE="Enabled"
fi

export PULL_SECRET_CONTENT SSH_PUB_KEY OS_IMAGE_BLOCK SECURE_BOOT_MODE

RENDERED_INSTALL_CONFIG="${REPO_ROOT}/generated/install-config.yaml"
python3 - "${REPO_ROOT}/templates/install-config.yaml.tpl" "${RENDERED_INSTALL_CONFIG}" << 'PYEOF'
import os
import sys

tpl_path, out_path = sys.argv[1], sys.argv[2]
with open(tpl_path, "r", encoding="utf-8") as f:
    content = f.read()

vars_to_replace = [
    "BASE_DOMAIN", "CLUSTER_NAME", "VPC_CIDR", "PROJECT_ID", "REGION",
    "VPC_NAME", "SUBNET_CONTROL_PLANE", "SUBNET_WORKER",
    "PULL_SECRET_CONTENT", "SSH_PUB_KEY", "OS_IMAGE_BLOCK", "SECURE_BOOT_MODE"
]
for var in vars_to_replace:
    content = content.replace(f"${{{var}}}", os.environ.get(var, ""))

with open(out_path, "w", encoding="utf-8") as f:
    f.write(content)
PYEOF
chmod 600 "${RENDERED_INSTALL_CONFIG}"
echo "[CREATED] Rendered ${RENDERED_INSTALL_CONFIG}"

echo ""
echo "=============================================================================="
echo " Step 2: Deploying Private Linux Bastion VM (${BASTION_NAME})"
echo "   Subnet : ${SUBNET_BASTION}"
echo "   Zone   : ${ZONE}"
echo "=============================================================================="
if gcloud compute instances describe "${BASTION_NAME}" \
    --zone="${ZONE}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "[SKIP] Bastion VM '${BASTION_NAME}' already exists in ${ZONE}."
else
  gcloud compute instances create "${BASTION_NAME}" \
    --project="${PROJECT_ID}" \
    --zone="${ZONE}" \
    --machine-type="e2-standard-4" \
    --network-interface="subnet=${SUBNET_BASTION},no-address" \
    --image-family="debian-13" \
    --image-project="debian-cloud" \
    --boot-disk-size="100GB" \
    --boot-disk-type="pd-ssd" \
    --shielded-secure-boot \
    --shielded-vtpm \
    --shielded-integrity-monitoring \
    --service-account="${SA_EMAIL}" \
    --scopes="https://www.googleapis.com/auth/cloud-platform" \
    --tags="ocp-bastion"
  echo "[CREATED] Bastion VM '${BASTION_NAME}'."
fi

echo ""
echo "=============================================================================="
echo " Step 3: Waiting for Bastion SSH Readiness via Cloud IAP"
echo "=============================================================================="
MAX_RETRIES=15
for ((i=1; i<=MAX_RETRIES; i++)); do
  if gcloud compute ssh "${BASTION_NAME}" \
      --project="${PROJECT_ID}" \
      --zone="${ZONE}" \
      --tunnel-through-iap \
      --command="mkdir -p ~/ocp-setup" >/dev/null 2>&1; then
    echo "[READY] Bastion VM is reachable via IAP SSH!"
    break
  fi
  echo "  Waiting for SSH daemon on ${BASTION_NAME} (attempt ${i}/${MAX_RETRIES})..."
  sleep 10
  if [[ "${i}" -eq "${MAX_RETRIES}" ]]; then
    echo "ERROR: Timed out waiting for SSH access to ${BASTION_NAME}."
    exit 1
  fi
done

echo ""
echo "=============================================================================="
echo " Step 4: Copying Required Installation, Phase 2 & Phase 3 Files to Bastion VM"
echo "=============================================================================="
gcloud compute scp --recurse --compress \
  --project="${PROJECT_ID}" \
  --zone="${ZONE}" \
  --tunnel-through-iap \
  "${REPO_ROOT}/config.env" \
  "${RENDERED_INSTALL_CONFIG}" \
  "${SA_KEY_FILE}" \
  "${SSH_KEY_FILE}" \
  "${SSH_KEY_FILE}.pub" \
  "${PULL_SECRET_FILE}" \
  "${REPO_ROOT}/scripts/05-bastion-install-ocp.sh" \
  "${REPO_ROOT}/workloads" \
  "${REPO_ROOT}/workload-manager" \
  "${BASTION_NAME}:~/ocp-setup/"

gcloud compute ssh "${BASTION_NAME}" \
  --project="${PROJECT_ID}" \
  --zone="${ZONE}" \
  --tunnel-through-iap \
  --command="chmod 600 ~/ocp-setup/*-ssh ~/ocp-setup/*-sa-key.json ~/ocp-setup/install-config.yaml ~/ocp-setup/pull-secret.txt && chmod +x ~/ocp-setup/05-bastion-install-ocp.sh ~/ocp-setup/workloads/option1-filestore-stateless/scripts/*.sh ~/ocp-setup/workloads/option2-hyperdisk-stateful/scripts/*.sh ~/ocp-setup/workload-manager/scripts/*.sh"

echo ""
echo "=============================================================================="
echo " Bastion Setup & File Transfer Complete!"
echo "=============================================================================="
echo " OpenShift installation is configured to start MANUALLY from the Bastion VM."
echo ""
echo " 1. SSH into the Bastion VM using the IAP tunnel command:"
echo "    gcloud compute ssh ${BASTION_NAME} --project=\"${PROJECT_ID}\" --zone=\"${ZONE}\" --tunnel-through-iap"
echo ""
echo " 2. Once logged into the Bastion VM, start the OpenShift installation:"
echo "    ~/ocp-setup/05-bastion-install-ocp.sh"
echo "=============================================================================="
