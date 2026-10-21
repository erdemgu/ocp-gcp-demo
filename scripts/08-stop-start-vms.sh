#!/usr/bin/env bash
# ==============================================================================
# 08-stop-start-vms.sh
# Gracefully stops, starts, or checks the status of all OpenShift Cluster VMs
# (Control Plane masters + Worker nodes across all zones) and the Bastion VM
# to save Google Cloud compute costs when the demo environment is idle.
#
# Usage:
#   ./scripts/08-stop-start-vms.sh status
#   ./scripts/08-stop-start-vms.sh stop [--keep-bastion]
#   ./scripts/08-stop-start-vms.sh start
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -f "${REPO_ROOT}/config.env" ]]; then
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/config.env"
elif [[ -f "${HOME}/ocp-setup/config.env" ]]; then
  # shellcheck source=/dev/null
  source "${HOME}/ocp-setup/config.env"
else
  echo "ERROR: config.env not found. Please run ./scripts/00-prereq-config.sh first."
  exit 1
fi

ACTION="${1:-status}"
OPTION="${2:-}"

ON_BASTION="false"
if [[ "$(hostname)" == "${BASTION_NAME}" || "$(hostname)" == *"-vm-bastion"* ]]; then
  ON_BASTION="true"
fi

# Helper: list VMs matching a regex filter as "name|zone|status"
list_vms() {
  local name_regex="$1"
  gcloud compute instances list \
    --project="${PROJECT_ID}" \
    --filter="name~'${name_regex}' AND zone:(${REGION}-a ${REGION}-b ${REGION}-c ${REGION}-d ${REGION}-f ${ZONE})" \
    --format="csv[no-heading](name,zone.basename(),status)" 2>/dev/null || true
}

show_status() {
  echo "=============================================================================="
  echo " OpenShift Cluster & Bastion VM Power Status"
  echo "   Project : ${PROJECT_ID}"
  echo "   Region  : ${REGION}"
  echo "   Cluster : ${CLUSTER_NAME}"
  echo "=============================================================================="
  gcloud compute instances list \
    --project="${PROJECT_ID}" \
    --filter="name~'^(${CLUSTER_NAME}-.*|${BASTION_NAME})$'" \
    --format="table(name,zone.basename(),machineType.basename(),networkInterfaces[0].networkIP:label=INTERNAL_IP,status)"
}

stop_vms() {
  local keep_bastion="false"
  if [[ "${OPTION}" == "--keep-bastion" || "${ON_BASTION}" == "true" ]]; then
    keep_bastion="true"
  fi

  echo "=============================================================================="
  echo " Stopping OpenShift Cluster VMs (${CLUSTER_NAME})"
  echo "=============================================================================="

  # 1. Stop Worker VMs first (grouped by zone)
  echo "--- Step 1: Stopping Worker Nodes ---"
  local worker_lines
  worker_lines="$(list_vms "^${CLUSTER_NAME}-.*-worker-.*")"
  if [[ -z "${worker_lines}" ]]; then
    echo "  No worker VMs found for '${CLUSTER_NAME}'."
  else
    while IFS=, read -r vm_name vm_zone vm_status; do
      [[ -z "${vm_name}" ]] && continue
      if [[ "${vm_status}" == "RUNNING" ]]; then
        echo "  -> Stopping worker ${vm_name} (${vm_zone})..."
        gcloud compute instances stop "${vm_name}" \
          --zone="${vm_zone}" \
          --project="${PROJECT_ID}" \
          --quiet
      else
        echo "  [SKIP] Worker ${vm_name} (${vm_zone}) is already ${vm_status}."
      fi
    done <<< "${worker_lines}"
  fi

  # 2. Stop Control Plane (Master) VMs second
  echo ""
  echo "--- Step 2: Stopping Control Plane (Master) Nodes ---"
  local master_lines
  master_lines="$(list_vms "^${CLUSTER_NAME}-.*-master-.*")"
  if [[ -z "${master_lines}" ]]; then
    echo "  No master VMs found for '${CLUSTER_NAME}'."
  else
    while IFS=, read -r vm_name vm_zone vm_status; do
      [[ -z "${vm_name}" ]] && continue
      if [[ "${vm_status}" == "RUNNING" ]]; then
        echo "  -> Stopping master ${vm_name} (${vm_zone})..."
        gcloud compute instances stop "${vm_name}" \
          --zone="${vm_zone}" \
          --project="${PROJECT_ID}" \
          --quiet
      else
        echo "  [SKIP] Master ${vm_name} (${vm_zone}) is already ${vm_status}."
      fi
    done <<< "${master_lines}"
  fi

  # 3. Stop Bastion VM last (unless --keep-bastion or running inside Bastion)
  echo ""
  echo "--- Step 3: Bastion VM (${BASTION_NAME}) ---"
  if [[ "${keep_bastion}" == "true" ]]; then
    echo "  [SKIP] Keeping Bastion VM '${BASTION_NAME}' running."
  else
    local bastion_status
    bastion_status="$(gcloud compute instances describe "${BASTION_NAME}" \
      --zone="${ZONE}" --project="${PROJECT_ID}" \
      --format="value(status)" 2>/dev/null || echo "NOT_FOUND")"
    if [[ "${bastion_status}" == "RUNNING" ]]; then
      echo "  -> Stopping Bastion VM ${BASTION_NAME} (${ZONE})..."
      gcloud compute instances stop "${BASTION_NAME}" \
        --zone="${ZONE}" \
        --project="${PROJECT_ID}" \
        --quiet
    else
      echo "  [SKIP] Bastion VM ${BASTION_NAME} is ${bastion_status}."
    fi
  fi

  echo ""
  show_status
}

start_vms() {
  echo "=============================================================================="
  echo " Starting OpenShift Cluster & Bastion VMs (${CLUSTER_NAME})"
  echo "=============================================================================="

  # 1. Start Bastion VM first
  echo "--- Step 1: Starting Bastion VM (${BASTION_NAME}) ---"
  local bastion_status
  bastion_status="$(gcloud compute instances describe "${BASTION_NAME}" \
    --zone="${ZONE}" --project="${PROJECT_ID}" \
    --format="value(status)" 2>/dev/null || echo "NOT_FOUND")"
  if [[ "${bastion_status}" == "TERMINATED" || "${bastion_status}" == "STOPPED" ]]; then
    echo "  -> Starting Bastion VM ${BASTION_NAME} (${ZONE})..."
    gcloud compute instances start "${BASTION_NAME}" \
      --zone="${ZONE}" \
      --project="${PROJECT_ID}" \
      --quiet
  else
    echo "  [OK] Bastion VM ${BASTION_NAME} is ${bastion_status}."
  fi

  # 2. Start Control Plane (Master) VMs first so etcd & API server form quorum
  echo ""
  echo "--- Step 2: Starting Control Plane (Master) Nodes ---"
  local master_lines
  master_lines="$(list_vms "^${CLUSTER_NAME}-.*-master-.*")"
  if [[ -z "${master_lines}" ]]; then
    echo "  No master VMs found for '${CLUSTER_NAME}'."
  else
    while IFS=, read -r vm_name vm_zone vm_status; do
      [[ -z "${vm_name}" ]] && continue
      if [[ "${vm_status}" != "RUNNING" ]]; then
        echo "  -> Starting master ${vm_name} (${vm_zone})..."
        gcloud compute instances start "${vm_name}" \
          --zone="${vm_zone}" \
          --project="${PROJECT_ID}" \
          --quiet
      else
        echo "  [OK] Master ${vm_name} (${vm_zone}) is already RUNNING."
      fi
    done <<< "${master_lines}"
  fi

  # 3. Start Worker VMs across all zones
  echo ""
  echo "--- Step 3: Starting Worker Nodes ---"
  local worker_lines
  worker_lines="$(list_vms "^${CLUSTER_NAME}-.*-worker-.*")"
  if [[ -z "${worker_lines}" ]]; then
    echo "  No worker VMs found for '${CLUSTER_NAME}'."
  else
    while IFS=, read -r vm_name vm_zone vm_status; do
      [[ -z "${vm_name}" ]] && continue
      if [[ "${vm_status}" != "RUNNING" ]]; then
        echo "  -> Starting worker ${vm_name} (${vm_zone})..."
        gcloud compute instances start "${vm_name}" \
          --zone="${vm_zone}" \
          --project="${PROJECT_ID}" \
          --quiet
      else
        echo "  [OK] Worker ${vm_name} (${vm_zone}) is already RUNNING."
      fi
    done <<< "${worker_lines}"
  fi

  # 4. Wait for API server & approve any pending CSRs so nodes become Ready
  echo ""
  echo "--- Step 4: Waiting for OpenShift API & Approving Pending Node CSRs ---"
  if [[ "${ON_BASTION}" == "true" ]]; then
    export PATH="${HOME}/bin:${PATH}"
    export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
    for ((i=1; i<=30; i++)); do
      if oc get nodes >/dev/null 2>&1; then
        break
      fi
      echo "  Waiting for OpenShift API server to respond (attempt ${i}/30)..."
      sleep 10
    done
    for csr in $(oc get csr --no-headers 2>/dev/null | awk '/Pending/ {print $1}'); do
      oc adm certificate approve "${csr}" || true
    done
    oc get nodes -o wide || true
  else
    gcloud compute ssh "${BASTION_NAME}" \
      --project="${PROJECT_ID}" \
      --zone="${ZONE}" \
      --tunnel-through-iap \
      --command="
        export PATH=\"\$HOME/bin:\$PATH\"
        export KUBECONFIG=\"\$HOME/.kube/config\"
        for ((i=1; i<=30; i++)); do
          if oc get nodes >/dev/null 2>&1; then
            break
          fi
          echo \"  Waiting for OpenShift API server to respond (attempt \${i}/30)...\"
          sleep 10
        done
        for csr in \$(oc get csr --no-headers 2>/dev/null | awk '/Pending/ {print \$1}'); do
          oc adm certificate approve \"\${csr}\" || true
        done
        echo ''
        oc get nodes -o wide || true
      " || true
  fi

  echo ""
  show_status
}

case "${ACTION}" in
  status)
    show_status
    ;;
  stop)
    stop_vms
    ;;
  start)
    start_vms
    ;;
  *)
    echo "Usage: $0 [status|stop|start] [--keep-bastion]"
    echo ""
    echo "Commands:"
    echo "  status                 Show current RUNNING/TERMINATED state of all Cluster & Bastion VMs"
    echo "  stop                   Gracefully stop Workers -> Control Plane Masters -> Bastion VM"
    echo "  stop --keep-bastion    Stop Cluster VMs (Workers + Masters) but keep Bastion VM running"
    echo "  start                  Start Bastion -> Control Plane Masters -> Workers & approve CSRs"
    exit 1
    ;;
esac
