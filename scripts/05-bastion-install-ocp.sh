#!/usr/bin/env bash
# ==============================================================================
# 05-bastion-install-ocp.sh
# RUN THIS SCRIPT MANUALLY INSIDE THE BASTION VM AFTER SSH LOGIN!
#
# What it does:
#   1. Installs required tools (wget, tar, jq, httpd-tools/htpasswd)
#   2. Downloads openshift-install, oc, and kubectl CLI binaries (if not installed)
#   3. Configures GOOGLE_APPLICATION_CREDENTIALS and SSH key agent
#   4. Stages ~/ocp-cluster/install-config.yaml (keeping a backup)
#   5. Runs `openshift-install create cluster --dir=$HOME/ocp-cluster --log-level=info`
#   6. Configures ~/.kube/config for immediate cluster administration
# ==============================================================================
set -euo pipefail

SETUP_DIR="${HOME}/ocp-setup"
CLUSTER_DIR="${HOME}/ocp-cluster"
ACTION="${1:-install}"

if [[ ! -f "${SETUP_DIR}/config.env" ]]; then
  echo "ERROR: ${SETUP_DIR}/config.env not found. Make sure you are running this on the Bastion VM."
  exit 1
fi
# shellcheck source=/dev/null
source "${SETUP_DIR}/config.env"
OCP_VERSION="${OCP_VERSION:-4.22.16}"
export PATH="${HOME}/bin:${PATH}"
export GOOGLE_APPLICATION_CREDENTIALS="${SETUP_DIR}/${PREFIX}-sa-key.json"

print_failure_and_recovery_commands() {
  cat <<EOF

==============================================================================
 [!] OpenShift Installation Failed or Interrupted — Recovery & Cleanup Commands
==============================================================================

Option A: Resume / Wait for Install Completion (if transient timeout)
------------------------------------------------------------------------------
export GOOGLE_APPLICATION_CREDENTIALS="${SETUP_DIR}/${PREFIX}-sa-key.json"
openshift-install wait-for bootstrap-complete --dir="${CLUSTER_DIR}" --log-level=info
openshift-install wait-for install-complete --dir="${CLUSTER_DIR}" --log-level=info

Option B: Delete / Destroy the Cluster Only
------------------------------------------------------------------------------
export GOOGLE_APPLICATION_CREDENTIALS="${SETUP_DIR}/${PREFIX}-sa-key.json"
openshift-install destroy cluster --dir="${CLUSTER_DIR}" --log-level=info
rm -rf "${CLUSTER_DIR}"

  Shortcut: ~/ocp-setup/05-bastion-install-ocp.sh destroy

Option C: Clean Destroy & Restart Installation from Scratch
------------------------------------------------------------------------------
export GOOGLE_APPLICATION_CREDENTIALS="${SETUP_DIR}/${PREFIX}-sa-key.json"
openshift-install destroy cluster --dir="${CLUSTER_DIR}" --log-level=info
rm -rf "${CLUSTER_DIR}"
mkdir -p "${CLUSTER_DIR}"
cp "${SETUP_DIR}/install-config.yaml.bak" "${CLUSTER_DIR}/install-config.yaml"
openshift-install create cluster --dir="${CLUSTER_DIR}" --log-level=info

  Shortcut: ~/ocp-setup/05-bastion-install-ocp.sh restart
==============================================================================
EOF
}

if [[ "${ACTION}" == "destroy" ]]; then
  echo "=============================================================================="
  echo " Destroying OpenShift Cluster (${CLUSTER_NAME}) in ${CLUSTER_DIR}"
  echo "=============================================================================="
  gcloud auth activate-service-account --key-file="${GOOGLE_APPLICATION_CREDENTIALS}" --project="${PROJECT_ID}"
  openshift-install destroy cluster --dir="${CLUSTER_DIR}" --log-level=info
  rm -rf "${CLUSTER_DIR}"
  echo "[DONE] Cluster destroyed and ${CLUSTER_DIR} cleaned up."
  exit 0
fi

if [[ "${ACTION}" == "restart" ]]; then
  echo "=============================================================================="
  echo " Destroying Failed Cluster & Restarting Fresh Installation (${CLUSTER_NAME})"
  echo "=============================================================================="
  gcloud auth activate-service-account --key-file="${GOOGLE_APPLICATION_CREDENTIALS}" --project="${PROJECT_ID}"
  if [[ -d "${CLUSTER_DIR}" && -f "${CLUSTER_DIR}/metadata.json" ]]; then
    openshift-install destroy cluster --dir="${CLUSTER_DIR}" --log-level=info
  fi
  rm -rf "${CLUSTER_DIR}"
  echo "[CLEANED] Proceeding with fresh installation..."
fi

echo "=============================================================================="
echo " Preparing Bastion Environment for OpenShift Installation"
echo "   OCP Version  : ${OCP_VERSION}"
echo "   Cluster Name : ${CLUSTER_NAME}"
echo "   Base Domain  : ${BASE_DOMAIN}"
echo "   Project ID   : ${PROJECT_ID}"
echo "   Region       : ${REGION}"
echo "=============================================================================="

# 1. Install helper packages (jq, wget, tar, httpd-tools for htpasswd)
echo "--- Step 1: Checking system packages ---"
if command -v dnf >/dev/null 2>&1; then
  sudo dnf install -y wget tar jq httpd-tools bind-utils >/dev/null
elif command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update -y >/dev/null
  sudo apt-get install -y wget tar jq apache2-utils dnsutils >/dev/null
fi

# 2. Download OpenShift CLI (oc, kubectl) and Installer (openshift-install)
mkdir -p "${HOME}/bin"
export PATH="${HOME}/bin:${PATH}"
if ! grep -q '$HOME/bin' "${HOME}/.bashrc" 2>/dev/null; then
  echo 'export PATH="$HOME/bin:$PATH"' >> "${HOME}/.bashrc"
fi

MIRROR_BASE="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OCP_VERSION}"

if ! command -v openshift-install >/dev/null 2>&1; then
  echo "--- Step 2a: Downloading openshift-install (${OCP_VERSION}) ---"
  wget -q --show-progress -O /tmp/openshift-install-linux.tar.gz "${MIRROR_BASE}/openshift-install-linux.tar.gz"
  tar -xzf /tmp/openshift-install-linux.tar.gz -C "${HOME}/bin" openshift-install
  rm -f /tmp/openshift-install-linux.tar.gz
  chmod +x "${HOME}/bin/openshift-install"
else
  echo "[SKIP] openshift-install already present: $(openshift-install version | head -n 1)"
fi

if ! command -v oc >/dev/null 2>&1; then
  echo "--- Step 2b: Downloading oc and kubectl CLI (${OCP_VERSION}) ---"
  wget -q --show-progress -O /tmp/openshift-client-linux.tar.gz "${MIRROR_BASE}/openshift-client-linux.tar.gz"
  tar -xzf /tmp/openshift-client-linux.tar.gz -C "${HOME}/bin" oc kubectl
  rm -f /tmp/openshift-client-linux.tar.gz
  chmod +x "${HOME}/bin/oc" "${HOME}/bin/kubectl"
else
  echo "[SKIP] oc CLI already present: $(oc version --client | head -n 1)"
fi

# 3. Configure GCP Service Account Credentials and SSH Key
echo "--- Step 3: Configuring GCP Credentials & SSH Agent ---"
export GOOGLE_APPLICATION_CREDENTIALS="${SETUP_DIR}/${PREFIX}-sa-key.json"
if ! grep -q "GOOGLE_APPLICATION_CREDENTIALS" "${HOME}/.bashrc" 2>/dev/null; then
  echo "export GOOGLE_APPLICATION_CREDENTIALS=\"${SETUP_DIR}/${PREFIX}-sa-key.json\"" >> "${HOME}/.bashrc"
fi

gcloud auth activate-service-account --key-file="${GOOGLE_APPLICATION_CREDENTIALS}" --project="${PROJECT_ID}"

eval "$(ssh-agent -s)"
ssh-add "${SETUP_DIR}/${PREFIX}-ssh"

# 4. Prepare Installation Directory & Backup install-config.yaml
echo "--- Step 4: Preparing Installation Directory (${CLUSTER_DIR}) ---"
mkdir -p "${CLUSTER_DIR}"
cp "${SETUP_DIR}/install-config.yaml" "${SETUP_DIR}/install-config.yaml.bak"
cp "${SETUP_DIR}/install-config.yaml" "${CLUSTER_DIR}/install-config.yaml"
chmod 600 "${CLUSTER_DIR}/install-config.yaml"

echo ""
echo "=============================================================================="
echo " Ready to Start OpenShift Self-Managed Private Cluster Installation"
echo "   Control Plane : 3x e2-standard-4 (100GB pd-ssd)"
echo "   Workers       : 3x n4-custom-6-20480 (200GB hyperdisk-balanced)"
echo "   Publish Mode  : Internal (Private Cluster)"
echo "=============================================================================="
read -r -p "Start OpenShift cluster installation now? [y/N]: " CONFIRM_INSTALL
if [[ ! "${CONFIRM_INSTALL}" =~ ^[Yy]$ ]]; then
  echo "Installation cancelled. You can re-run ~/ocp-setup/05-bastion-install-ocp.sh anytime."
  exit 0
fi

# 5. Run OpenShift Installer (catch failure to print restart/delete commands)
if ! openshift-install create cluster --dir="${CLUSTER_DIR}" --log-level=info; then
  print_failure_and_recovery_commands
  exit 1
fi

# 6. Configure KUBECONFIG for the bastion user
mkdir -p "${HOME}/.kube"
cp "${CLUSTER_DIR}/auth/kubeconfig" "${HOME}/.kube/config"
chmod 600 "${HOME}/.kube/config"
if ! grep -q "KUBECONFIG=" "${HOME}/.bashrc" 2>/dev/null; then
  echo 'export KUBECONFIG="$HOME/.kube/config"' >> "${HOME}/.bashrc"
fi
export KUBECONFIG="${HOME}/.kube/config"

echo ""
echo "=============================================================================="
echo " OpenShift Cluster Installation Completed Successfully!"
echo "=============================================================================="
echo " Web Console URL : https://console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"
echo " Kubeadmin User  : kubeadmin"
echo " Kubeadmin Pass  : $(cat "${CLUSTER_DIR}/auth/kubeadmin-password")"
echo ""
echo " Verifying cluster nodes:"
oc get nodes -o wide
echo ""
echo "=============================================================================="
echo " NEXT STEP (Run on your LOCAL WORKSTATION, NOT on this Bastion VM):"
echo "   1. Exit this Bastion SSH session (or open a local terminal on your laptop/workstation)"
echo "   2. Run: ./scripts/06-access-and-test.sh test"
echo "   3. Run: ./scripts/06-access-and-test.sh hosts"
echo "   4. Run: ./scripts/06-access-and-test.sh tunnel"
echo "=============================================================================="
