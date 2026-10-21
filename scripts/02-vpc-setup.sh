#!/usr/bin/env bash
# ==============================================================================
# 02-vpc-setup.sh
# Deploys the Custom VPC, 3 Subnets (control-plane, worker, bastion),
# Cloud Router + Cloud NAT for outbound internet access, and Firewall Rules.
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
echo " Deploying VPC & Network Infrastructure in Project: ${PROJECT_ID}"
echo "   VPC Name             : ${VPC_NAME} (${VPC_CIDR})"
echo "   Control Plane Subnet : ${SUBNET_CONTROL_PLANE} (${CONTROL_PLANE_CIDR})"
echo "   Worker Subnet        : ${SUBNET_WORKER} (${WORKER_CIDR})"
echo "   Bastion Subnet       : ${SUBNET_BASTION} (${BASTION_CIDR})"
echo "   Cloud Router & NAT   : ${ROUTER_NAME} / ${NAT_NAME}"
echo "=============================================================================="

# 1. Create Custom VPC
if gcloud compute networks describe "${VPC_NAME}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "[SKIP] VPC '${VPC_NAME}' already exists."
else
  echo "[CREATE] Creating custom VPC '${VPC_NAME}'..."
  gcloud compute networks create "${VPC_NAME}" \
    --project="${PROJECT_ID}" \
    --subnet-mode=custom \
    --bgp-routing-mode=regional
fi

# Helper function to create subnet with Private Google Access enabled
create_subnet() {
  local subnet_name="$1"
  local subnet_cidr="$2"
  if gcloud compute networks subnets describe "${subnet_name}" \
      --region="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    echo "[SKIP] Subnet '${subnet_name}' already exists."
  else
    echo "[CREATE] Creating subnet '${subnet_name}' (${subnet_cidr}) in ${REGION}..."
    gcloud compute networks subnets create "${subnet_name}" \
      --project="${PROJECT_ID}" \
      --network="${VPC_NAME}" \
      --region="${REGION}" \
      --range="${subnet_cidr}" \
      --enable-private-ip-google-access
  fi
}

# 2. Create the 3 Subnets
create_subnet "${SUBNET_CONTROL_PLANE}" "${CONTROL_PLANE_CIDR}"
create_subnet "${SUBNET_WORKER}" "${WORKER_CIDR}"
create_subnet "${SUBNET_BASTION}" "${BASTION_CIDR}"

# 3. Create Cloud Router for Cloud NAT
if gcloud compute routers describe "${ROUTER_NAME}" \
    --region="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "[SKIP] Cloud Router '${ROUTER_NAME}' already exists."
else
  echo "[CREATE] Creating Cloud Router '${ROUTER_NAME}' in ${REGION}..."
  gcloud compute routers create "${ROUTER_NAME}" \
    --project="${PROJECT_ID}" \
    --network="${VPC_NAME}" \
    --region="${REGION}"
fi

# 4. Create Cloud NAT for Outbound Internet Access across all 3 private subnets
if gcloud compute routers nats describe "${NAT_NAME}" \
    --router="${ROUTER_NAME}" --region="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "[SKIP] Cloud NAT '${NAT_NAME}' already exists."
else
  echo "[CREATE] Creating Cloud NAT '${NAT_NAME}' for outbound internet access..."
  gcloud compute routers nats create "${NAT_NAME}" \
    --project="${PROJECT_ID}" \
    --router="${ROUTER_NAME}" \
    --region="${REGION}" \
    --nat-all-subnet-ip-ranges \
    --auto-allocate-nat-external-ips \
    --enable-dynamic-port-allocation \
    --min-ports-per-vm=1024 \
    --max-ports-per-vm=65536
fi

# 5. Create Firewall Rule for Identity-Aware Proxy (IAP) SSH access to Bastion
if gcloud compute firewall-rules describe "${FW_IAP_SSH}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "[SKIP] Firewall rule '${FW_IAP_SSH}' already exists."
else
  echo "[CREATE] Creating IAP SSH firewall rule '${FW_IAP_SSH}'..."
  gcloud compute firewall-rules create "${FW_IAP_SSH}" \
    --project="${PROJECT_ID}" \
    --network="${VPC_NAME}" \
    --direction=INGRESS \
    --action=ALLOW \
    --rules=tcp:22 \
    --source-ranges=35.235.240.0/20 \
    --description="Allow SSH access via Cloud Identity-Aware Proxy (IAP)"
fi

# 6. Create Firewall Rule for Internal VPC Communication (Bastion <-> Cluster API/Ingress)
if gcloud compute firewall-rules describe "${FW_INTERNAL}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "[SKIP] Firewall rule '${FW_INTERNAL}' already exists."
else
  echo "[CREATE] Creating internal VPC firewall rule '${FW_INTERNAL}'..."
  gcloud compute firewall-rules create "${FW_INTERNAL}" \
    --project="${PROJECT_ID}" \
    --network="${VPC_NAME}" \
    --direction=INGRESS \
    --action=ALLOW \
    --rules=tcp,udp,icmp \
    --source-ranges="${VPC_CIDR}" \
    --description="Allow internal communication across Bastion, Control Plane, and Worker subnets"
fi

echo ""
echo "=============================================================================="
echo " VPC, 3 Subnets, Cloud NAT, and Firewall Rules are ready!"
echo "=============================================================================="
gcloud compute networks subnets list --network="${VPC_NAME}" --project="${PROJECT_ID}"
echo ""
echo "Next step: Run ./scripts/03-iam-and-keys.sh"
