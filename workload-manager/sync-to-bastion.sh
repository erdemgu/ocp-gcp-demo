#!/usr/bin/env bash
# ==============================================================================
# workload-manager/sync-to-bastion.sh
# Run on your LOCAL WORKSTATION to copy the Phase 3 workload-manager/
# directory and config.env to ~/ocp-setup/ on the Bastion VM via Cloud IAP SCP.
# ==============================================================================
set -euo pipefail

if [[ "$(hostname)" == *"-vm-bastion"* ]]; then
  echo "ERROR: sync-to-bastion.sh must be run on your LOCAL WORKSTATION, not inside the Bastion VM."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ ! -f "${REPO_ROOT}/config.env" ]]; then
  echo "ERROR: ${REPO_ROOT}/config.env not found. Please run ./scripts/00-prereq-config.sh first."
  exit 1
fi
# shellcheck source=/dev/null
source "${REPO_ROOT}/config.env"

echo "=============================================================================="
echo " Syncing Phase 3 (Workload Manager & Telemetry) to Bastion VM (${BASTION_NAME})"
echo "   Project : ${PROJECT_ID}"
echo "   Zone    : ${ZONE}"
echo "   Target  : ${BASTION_NAME}:~/ocp-setup/workload-manager/"
echo "=============================================================================="

BASTION_STATUS="$(gcloud compute instances describe "${BASTION_NAME}" \
  --zone="${ZONE}" --project="${PROJECT_ID}" \
  --format="value(status)" 2>/dev/null || echo "NOT_FOUND")"

if [[ "${BASTION_STATUS}" != "RUNNING" ]]; then
  echo "ERROR: Bastion VM '${BASTION_NAME}' is currently '${BASTION_STATUS}'."
  echo "       Start the cluster and Bastion VMs first with: ./scripts/08-stop-start-vms.sh start"
  exit 1
fi

gcloud compute ssh "${BASTION_NAME}" \
  --project="${PROJECT_ID}" \
  --zone="${ZONE}" \
  --tunnel-through-iap \
  --command="mkdir -p ~/ocp-setup/workload-manager"

gcloud compute scp --recurse --compress \
  --project="${PROJECT_ID}" \
  --zone="${ZONE}" \
  --tunnel-through-iap \
  "${REPO_ROOT}/config.env" \
  "${REPO_ROOT}/workload-manager" \
  "${BASTION_NAME}:~/ocp-setup/"

gcloud compute ssh "${BASTION_NAME}" \
  --project="${PROJECT_ID}" \
  --zone="${ZONE}" \
  --tunnel-through-iap \
  --command="chmod +x ~/ocp-setup/workload-manager/scripts/*.sh"

echo ""
echo "=============================================================================="
echo " Phase 3 Files Synced Successfully!"
echo "=============================================================================="
echo " Next steps inside the Bastion VM (./scripts/06-access-and-test.sh ssh):"
echo ""
echo "   cd ~/ocp-setup/workload-manager"
echo "   ./scripts/01-prereq-wlm-iam.sh"
echo "   ./scripts/02-deploy-telemetry-operator.sh"
echo "   ./scripts/03-trigger-and-verify.sh"
echo "=============================================================================="
