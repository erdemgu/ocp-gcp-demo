#!/usr/bin/env bash
# ==============================================================================
# 00-prereq-config.sh
# Interactive Prerequisite Check & Environment Configuration Generator
# ==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${REPO_ROOT}/config.env"

# Detect Windows Subsystem for Linux (WSL)
IS_WSL="false"
if grep -qiE "(microsoft|wsl)" /proc/version 2>/dev/null; then
  IS_WSL="true"
  if [[ "${REPO_ROOT}" == /mnt/* ]]; then
    echo "WARNING: You are running inside Windows WSL from a mounted Windows drive (${REPO_ROOT})."
    echo "         Windows DrvFs (/mnt/c/...) ignores 'chmod 600' on SSH private keys by default,"
    echo "         which causes SSH and gcloud to reject the generated keys."
    echo "         RECOMMENDED: Clone and run this repository inside your native Linux home directory (e.g., ~/ocp-gcp-demo)."
    echo ""
  fi
fi

echo "=============================================================================="
echo " Red Hat OpenShift Self-Managed on Google Cloud - Prerequisite Setup"
echo "=============================================================================="
echo ""
echo "Before proceeding, please confirm the following prerequisites:"
echo "  1. You have an existing Google Cloud Project with Billing enabled."
echo "  2. You have an active Red Hat account (https://console.redhat.com)."
echo "  3. You have downloaded your Red Hat Pull Secret file (pull-secret.txt)"
echo "     from: https://console.redhat.com/openshift/install/pull-secret"
echo ""

read -r -p "Do you have an existing GCP project, Red Hat account, and Pull Secret file? [y/N]: " PREREQ_CONFIRM
if [[ ! "${PREREQ_CONFIRM}" =~ ^[Yy]$ ]]; then
  echo "ERROR: Please complete the prerequisites above before continuing."
  exit 1
fi

echo ""
echo "--- Step 1: Google Cloud Project & Region ---"
read -r -p "Enter existing GCP Project ID: " PROJECT_ID
if [[ -z "${PROJECT_ID}" ]]; then
  echo "ERROR: Project ID cannot be empty."
  exit 1
fi

read -r -p "Enter GCP Region (e.g., us-central1, europe-west1, asia-southeast1): " REGION
if [[ -z "${REGION}" ]]; then
  echo "ERROR: Region cannot be empty."
  exit 1
fi

read -r -p "Enter default GCP Zone for Bastion VM [${REGION}-a]: " INPUT_ZONE
ZONE="${INPUT_ZONE:-${REGION}-a}"

echo ""
echo "--- Step 2: Naming Prefix & Private Local Domain ---"
echo "This prefix will be used for ALL resources (VPC, subnets, NAT, Bastion, SA, SSH key, cluster, domain)."
read -r -p "Enter Naming Prefix (lowercase letters, digits, hyphens, e.g., ocp-demo): " PREFIX
if [[ -z "${PREFIX}" ]]; then
  echo "ERROR: Naming prefix cannot be empty."
  exit 1
fi

if [[ ! "${PREFIX}" =~ ^[a-z][a-z0-9-]{1,18}[a-z0-9]$ ]]; then
  echo "ERROR: Naming prefix must start with a lowercase letter, contain only lowercase letters, numbers, or hyphens, and be 3-20 chars."
  exit 1
fi

DEFAULT_BASE_DOMAIN="${PREFIX}.openshiftapps.local"
read -r -p "Enter Private Local Domain [${DEFAULT_BASE_DOMAIN}]: " INPUT_BASE_DOMAIN
BASE_DOMAIN="${INPUT_BASE_DOMAIN:-${DEFAULT_BASE_DOMAIN}}"

echo ""
echo "--- Step 3: VPC IP Range (/20) ---"
echo "Provide a /20 CIDR range for the VPC. Three subnets will be carved out automatically:"
echo "  - Control Plane Subnet (/23)"
echo "  - Worker Subnet        (/23)"
echo "  - Bastion Subnet       (/24)"
read -r -p "Enter VPC CIDR Range (/20) [10.90.32.0/20]: " INPUT_VPC_CIDR
VPC_CIDR="${INPUT_VPC_CIDR:-10.90.32.0/20}"

# Validate /20 CIDR and compute the 3 subnet ranges using python3 ipaddress
SUBNET_CALC="$(python3 - "${VPC_CIDR}" << 'PYEOF'
import ipaddress
import sys

cidr_str = sys.argv[1]
try:
    net = ipaddress.ip_network(cidr_str, strict=False)
except ValueError as e:
    print(f"ERROR: Invalid CIDR '{cidr_str}': {e}", file=sys.stderr)
    sys.exit(1)

if net.version != 4 or net.prefixlen != 20:
    print(f"ERROR: CIDR '{cidr_str}' must be an IPv4 /20 network (e.g., 10.90.32.0/20).", file=sys.stderr)
    sys.exit(1)

# Carve /23 subnets from /20 (yields 8 /23 blocks)
subnets_23 = list(net.subnets(new_prefix=23))
cp_cidr = str(subnets_23[0])       # first /23 (e.g. 10.90.32.0/23)
worker_cidr = str(subnets_23[1])   # second /23 (e.g. 10.90.34.0/23)
# Carve /24 from the third /23 for the bastion subnet (e.g. 10.90.36.0/24)
bastion_cidr = str(list(subnets_23[2].subnets(new_prefix=24))[0])

print(f"{net}|{cp_cidr}|{worker_cidr}|{bastion_cidr}")
PYEOF
)"

IFS='|' read -r NORMALIZED_VPC_CIDR CONTROL_PLANE_CIDR WORKER_CIDR BASTION_CIDR <<< "${SUBNET_CALC}"
VPC_CIDR="${NORMALIZED_VPC_CIDR}"

echo "  -> Normalized VPC CIDR : ${VPC_CIDR}"
echo "  -> Control Plane (/23) : ${CONTROL_PLANE_CIDR}"
echo "  -> Worker Subnet (/23) : ${WORKER_CIDR}"
echo "  -> Bastion Subnet(/24) : ${BASTION_CIDR}"

echo ""
echo "--- Step 4: Red Hat Pull Secret File ---"
echo "  (Note: If you or your organization don't have a Red Hat subscription, you can open"
echo "   a Red Hat account for free at https://console.redhat.com/openshift/install/pull-secret"
echo "   and use the 60-day trial license for the deployment.)"
DEFAULT_PULL_SECRET="./pull-secret.txt"
read -r -p "Enter path to Red Hat Pull Secret file [${DEFAULT_PULL_SECRET}]: " INPUT_PULL_SECRET
PULL_SECRET_FILE="${INPUT_PULL_SECRET:-${DEFAULT_PULL_SECRET}}"
PULL_SECRET_FILE="${PULL_SECRET_FILE/#\~/$HOME}"

if [[ ! -f "${PULL_SECRET_FILE}" ]]; then
  echo "ERROR: Pull secret file not found at '${PULL_SECRET_FILE}'."
  exit 1
fi

# Validate JSON format of pull secret
if ! python3 -m json.tool "${PULL_SECRET_FILE}" > /dev/null 2>&1; then
  echo "ERROR: Pull secret file '${PULL_SECRET_FILE}' is not valid JSON."
  exit 1
fi

echo ""
echo "--- Step 5: Google Cloud Marketplace Offering (Optional) ---"
echo "More info: https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/installing_on_google_cloud/installing-gcp-customizations#installation-gcp-marketplace_installing-gcp-customizations"
echo "NOTE: If you change the OCP version from 4.22.16 to another version, check the article above for the matching Marketplace image ID and update it accordingly."
read -r -p "Do you want to use a Google Cloud Marketplace offering image for worker and master machines? [y/N]: " USE_MP_CONFIRM

USE_MARKETPLACE_IMAGE="false"
MARKETPLACE_IMAGE_PROJECT="redhat-marketplace-public"
MARKETPLACE_IMAGE_NAME="redhat-coreos-ocp-413-x86-64-202305021736"

if [[ "${USE_MP_CONFIRM}" =~ ^[Yy]$ ]]; then
  USE_MARKETPLACE_IMAGE="true"
  echo "Select the Google Cloud Marketplace offering:"
  echo "  1) OpenShift Container Platform (redhat-coreos-ocp-413-x86-64-202305021736)"
  echo "  2) OpenShift Platform Plus      (redhat-coreos-opp-413-x86-64-202305021736)"
  echo "  3) OpenShift Kubernetes Engine  (redhat-coreos-oke-413-x86-64-202305021736)"
  read -r -p "Enter option [1-3, default: 1]: " MP_OPTION
  case "${MP_OPTION:-1}" in
    1)
      MARKETPLACE_IMAGE_NAME="redhat-coreos-ocp-413-x86-64-202305021736"
      ;;
    2)
      MARKETPLACE_IMAGE_NAME="redhat-coreos-opp-413-x86-64-202305021736"
      ;;
    3)
      MARKETPLACE_IMAGE_NAME="redhat-coreos-oke-413-x86-64-202305021736"
      ;;
    *)
      echo "ERROR: Invalid Marketplace option '${MP_OPTION}'. Choose 1, 2, or 3."
      exit 1
      ;;
  esac
  echo "  -> Selected Marketplace Image: ${MARKETPLACE_IMAGE_PROJECT}/${MARKETPLACE_IMAGE_NAME}"
fi

# Derived resource names using PREFIX
VPC_NAME="${PREFIX}-vpc"
SUBNET_BASTION="${PREFIX}-subnet-bastion"
SUBNET_CONTROL_PLANE="${PREFIX}-subnet-control-plane"
SUBNET_WORKER="${PREFIX}-subnet-worker"
ROUTER_NAME="${PREFIX}-router"
NAT_NAME="${PREFIX}-nat"
FW_IAP_SSH="${PREFIX}-allow-iap-ssh"
FW_INTERNAL="${PREFIX}-allow-internal"
BASTION_NAME="${PREFIX}-vm-bastion"
SA_NAME="${PREFIX}-ocp-sa"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
CLUSTER_NAME="${PREFIX}-cluster"
OCP_VERSION="4.22.16"

mkdir -p "${REPO_ROOT}/generated"
cp "${PULL_SECRET_FILE}" "${REPO_ROOT}/generated/pull-secret.txt"
chmod 600 "${REPO_ROOT}/generated/pull-secret.txt"

# On Windows WSL2, default CONSOLE_LOCAL_IP to 127.0.0.1 because WSL2 NAT mode
# only forwards 127.0.0.1 from the Windows host browser into the WSL2 VM.
if [[ "${IS_WSL}" == "true" ]]; then
  DEFAULT_CONSOLE_LOCAL_IP="127.0.0.1"
else
  DEFAULT_CONSOLE_LOCAL_IP="127.0.0.2"
fi

cat <<EOF > "${CONFIG_FILE}"
# Auto-generated by scripts/00-prereq-config.sh
export PROJECT_ID="${PROJECT_ID}"
export REGION="${REGION}"
export ZONE="${ZONE}"
export PREFIX="${PREFIX}"

# Networking & Subnets
export VPC_CIDR="${VPC_CIDR}"
export CONTROL_PLANE_CIDR="${CONTROL_PLANE_CIDR}"
export WORKER_CIDR="${WORKER_CIDR}"
export BASTION_CIDR="${BASTION_CIDR}"
export VPC_NAME="${VPC_NAME}"
export SUBNET_BASTION="${SUBNET_BASTION}"
export SUBNET_CONTROL_PLANE="${SUBNET_CONTROL_PLANE}"
export SUBNET_WORKER="${SUBNET_WORKER}"
export ROUTER_NAME="${ROUTER_NAME}"
export NAT_NAME="${NAT_NAME}"
export FW_IAP_SSH="${FW_IAP_SSH}"
export FW_INTERNAL="${FW_INTERNAL}"

# Compute, IAM & Keys
export BASTION_NAME="${BASTION_NAME}"
export SA_NAME="${SA_NAME}"
export SA_EMAIL="${SA_EMAIL}"
export SA_KEY_FILE="${REPO_ROOT}/generated/${PREFIX}-sa-key.json"
export SSH_KEY_FILE="${REPO_ROOT}/generated/${PREFIX}-ssh"
export PULL_SECRET_FILE="${REPO_ROOT}/generated/pull-secret.txt"

# OpenShift Cluster Settings
export OCP_VERSION="${OCP_VERSION}"
export CLUSTER_NAME="${CLUSTER_NAME}"
export BASE_DOMAIN="${BASE_DOMAIN}"
export USE_MARKETPLACE_IMAGE="${USE_MARKETPLACE_IMAGE}"
export MARKETPLACE_IMAGE_PROJECT="${MARKETPLACE_IMAGE_PROJECT}"
export MARKETPLACE_IMAGE_NAME="${MARKETPLACE_IMAGE_NAME}"

# Local Loopback Tunnel IP (127.0.0.2 on Linux/macOS; 127.0.0.1 on Windows WSL2)
export CONSOLE_LOCAL_IP="${DEFAULT_CONSOLE_LOCAL_IP}"
EOF

echo ""
echo "=============================================================================="
echo " Configuration saved to: ${CONFIG_FILE}"
echo "=============================================================================="
cat "${CONFIG_FILE}"
echo ""
echo "Next step: Run ./scripts/01-policy-check.sh"
