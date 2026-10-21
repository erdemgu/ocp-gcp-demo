#!/usr/bin/env bash
# ==============================================================================
# 07-cleanup.sh
# Complete Teardown & Cleanup Script (Reverse Order of Creation):
#   1. Destroys the OpenShift cluster via Bastion VM (if ~/ocp-cluster exists)
#   2. Deletes the Bastion VM (${BASTION_NAME})
#   3. Deletes Firewall Rules (${FW_IAP_SSH}, ${FW_INTERNAL})
#   4. Deletes Cloud NAT (${NAT_NAME}) and Cloud Router (${ROUTER_NAME})
#   5. Deletes the 3 Subnets and Custom VPC (${VPC_NAME})
#   6. Deletes the OCP Service Account (${SA_EMAIL})
#   7. Cleans up local /etc/hosts entries and generated/ artifacts
# ==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ ! -f "${REPO_ROOT}/config.env" ]]; then
  echo "ERROR: config.env not found. Cannot determine resource names to delete."
  exit 1
fi
# shellcheck source=/dev/null
source "${REPO_ROOT}/config.env"

CONSOLE_HOST="console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"
OAUTH_HOST="oauth-openshift.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"

echo "=============================================================================="
echo " WARNING: This will permanently delete ALL demo resources for prefix '${PREFIX}'"
echo "   Project ID      : ${PROJECT_ID}"
echo "   OCP Cluster     : ${CLUSTER_NAME}.${BASE_DOMAIN}"
echo "   Bastion VM      : ${BASTION_NAME} (${ZONE})"
echo "   VPC & Subnets   : ${VPC_NAME}, ${SUBNET_CONTROL_PLANE}, ${SUBNET_WORKER}, ${SUBNET_BASTION}"
echo "   Cloud NAT/Router: ${NAT_NAME} / ${ROUTER_NAME}"
echo "   Service Account : ${SA_EMAIL}"
echo "=============================================================================="
read -r -p "Are you sure you want to destroy the cluster and all infrastructure? [y/N]: " CONFIRM
if [[ ! "${CONFIRM}" =~ ^[Yy]$ ]]; then
  echo "Cleanup cancelled."
  exit 0
fi

# 1. Destroy OpenShift Cluster from Bastion VM (if Bastion is running)
echo ""
echo "--- Step 1: Destroying OpenShift Cluster via Bastion VM ---"
if gcloud compute instances describe "${BASTION_NAME}" \
    --zone="${ZONE}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute ssh "${BASTION_NAME}" \
    --project="${PROJECT_ID}" \
    --zone="${ZONE}" \
    --tunnel-through-iap \
    --command="
      export PATH=\"\$HOME/bin:\$PATH\"
      export KUBECONFIG=\"\${KUBECONFIG:-\$HOME/.kube/config}\"
      if command -v oc >/dev/null 2>&1 && oc whoami >/dev/null 2>&1; then
        echo '[CLEANUP] Removing Phase 2 Cymbal workload namespaces (if present) so CSI volumes release cleanly...'
        oc delete namespace cymbal-storefront cymbal-stateful --ignore-not-found --wait=true || true
      fi
      if [[ -d \"\$HOME/ocp-cluster\" && -f \"\$HOME/ocp-cluster/metadata.json\" ]]; then
        ~/ocp-setup/05-bastion-install-ocp.sh destroy
      else
        echo '[SKIP] No active ~/ocp-cluster/metadata.json found on Bastion.'
      fi
    " || echo "[WARN] Could not run cluster destroy on Bastion; continuing infrastructure teardown."
else
  echo "[SKIP] Bastion VM '${BASTION_NAME}' does not exist."
fi

# 2. Delete Bastion VM
echo ""
echo "--- Step 2: Deleting Bastion VM (${BASTION_NAME}) ---"
if gcloud compute instances describe "${BASTION_NAME}" \
    --zone="${ZONE}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute instances delete "${BASTION_NAME}" \
    --zone="${ZONE}" --project="${PROJECT_ID}" --quiet
  echo "[DELETED] Bastion VM '${BASTION_NAME}'."
else
  echo "[SKIP] Bastion VM '${BASTION_NAME}' already deleted."
fi

# 3. Delete Firewall Rules
echo ""
echo "--- Step 3: Deleting Firewall Rules ---"
for fw in "${FW_IAP_SSH}" "${FW_INTERNAL}"; do
  if gcloud compute firewall-rules describe "${fw}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud compute firewall-rules delete "${fw}" --project="${PROJECT_ID}" --quiet
    echo "[DELETED] Firewall rule '${fw}'."
  else
    echo "[SKIP] Firewall rule '${fw}' not found."
  fi
done

# 4. Delete Cloud NAT & Cloud Router
echo ""
echo "--- Step 4: Deleting Cloud NAT (${NAT_NAME}) and Cloud Router (${ROUTER_NAME}) ---"
if gcloud compute routers nats describe "${NAT_NAME}" \
    --router="${ROUTER_NAME}" --region="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute routers nats delete "${NAT_NAME}" \
    --router="${ROUTER_NAME}" --region="${REGION}" --project="${PROJECT_ID}" --quiet
  echo "[DELETED] Cloud NAT '${NAT_NAME}'."
else
  echo "[SKIP] Cloud NAT '${NAT_NAME}' not found."
fi

if gcloud compute routers describe "${ROUTER_NAME}" \
    --region="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute routers delete "${ROUTER_NAME}" \
    --region="${REGION}" --project="${PROJECT_ID}" --quiet
  echo "[DELETED] Cloud Router '${ROUTER_NAME}'."
else
  echo "[SKIP] Cloud Router '${ROUTER_NAME}' not found."
fi

# 5. Delete Subnets, Phase 2 Filestore / Private Service Access (PSA), & Custom VPC
echo ""
echo "--- Step 5: Deleting Subnets, PSA Peering/Ranges, and VPC (${VPC_NAME}) ---"
for subnet in "${SUBNET_BASTION}" "${SUBNET_WORKER}" "${SUBNET_CONTROL_PLANE}"; do
  if gcloud compute networks subnets describe "${subnet}" \
      --region="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud compute networks subnets delete "${subnet}" \
      --region="${REGION}" --project="${PROJECT_ID}" --quiet
    echo "[DELETED] Subnet '${subnet}'."
  else
    echo "[SKIP] Subnet '${subnet}' not found."
  fi
done

# Delete any remaining Cloud Filestore instances attached to ${VPC_NAME}
FILESTORE_INSTANCES="$(gcloud filestore instances list \
  --project="${PROJECT_ID}" \
  --filter="networks.network~/${VPC_NAME}$" \
  --format="csv[no-heading](name,location)" 2>/dev/null || true)"
if [[ -n "${FILESTORE_INSTANCES}" ]]; then
  while IFS=',' read -r fs_name fs_loc; do
    [[ -z "${fs_name}" ]] && continue
    echo "  Deleting Filestore instance '${fs_name}' (${fs_loc}) attached to ${VPC_NAME}..."
    gcloud filestore instances delete "${fs_name}" \
      --location="${fs_loc}" --project="${PROJECT_ID}" --quiet || true
    echo "[DELETED] Filestore instance '${fs_name}'."
  done <<< "${FILESTORE_INSTANCES}"
fi

# Delete Service Networking VPC Peering & Private Service Access (PSA) IP range (${PREFIX}-psa-range)
PSA_RANGE_NAME="${PREFIX}-psa-range"
if gcloud compute networks peerings list \
    --network="${VPC_NAME}" --project="${PROJECT_ID}" 2>/dev/null | grep -q "servicenetworking-googleapis-com"; then
  gcloud compute networks peerings delete servicenetworking-googleapis-com \
    --network="${VPC_NAME}" --project="${PROJECT_ID}" --quiet || true
  echo "[DELETED] VPC peering 'servicenetworking-googleapis-com' on '${VPC_NAME}'."
fi

if gcloud compute addresses describe "${PSA_RANGE_NAME}" \
    --global --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute addresses delete "${PSA_RANGE_NAME}" \
    --global --project="${PROJECT_ID}" --quiet
  echo "[DELETED] Global PSA IP range '${PSA_RANGE_NAME}'."
else
  echo "[SKIP] Global PSA IP range '${PSA_RANGE_NAME}' not found."
fi

if gcloud compute networks describe "${VPC_NAME}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute networks delete "${VPC_NAME}" --project="${PROJECT_ID}" --quiet
  echo "[DELETED] VPC '${VPC_NAME}'."
else
  echo "[SKIP] VPC '${VPC_NAME}' not found."
fi

# 6. Delete Phase 2 Secret Manager Secrets & Service Accounts
echo ""
echo "--- Step 6: Deleting Phase 2 Secrets and Service Accounts (${SA_EMAIL}) ---"
for sec in "${PREFIX}-cymbal-db-password" "${PREFIX}-cymbal-api-key"; do
  if gcloud secrets describe "${sec}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud secrets delete "${sec}" --project="${PROJECT_ID}" --quiet
    echo "[DELETED] Secret Manager secret '${sec}'."
  else
    echo "[SKIP] Secret Manager secret '${sec}' not found."
  fi
done

for sa in "${SA_EMAIL}" "${PREFIX}-wlm-telemetry-sa@${PROJECT_ID}.iam.gserviceaccount.com"; do
  if gcloud iam service-accounts describe "${sa}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud iam service-accounts delete "${sa}" --project="${PROJECT_ID}" --quiet
    echo "[DELETED] Service Account '${sa}'."
  else
    echo "[SKIP] Service Account '${sa}' not found."
  fi
done

# 7. Clean up local /etc/hosts and generated files
echo ""
echo "--- Step 7: Cleaning up local /etc/hosts and generated/ files ---"
if grep -q "\.apps\.${CLUSTER_NAME}\.${BASE_DOMAIN}" /etc/hosts 2>/dev/null; then
  sudo sed -i.bak "/\.apps\.${CLUSTER_NAME}\.${BASE_DOMAIN}/d" /etc/hosts
  echo "[CLEANED] Removed *.apps.${CLUSTER_NAME}.${BASE_DOMAIN} entries from /etc/hosts."
fi

rm -rf "${REPO_ROOT}/generated"
echo "[CLEANED] Removed local ${REPO_ROOT}/generated directory."
echo ""
echo "=============================================================================="
echo " Teardown & Cleanup Complete!"
echo "=============================================================================="
