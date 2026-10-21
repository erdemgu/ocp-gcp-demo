#!/usr/bin/env bash
# ==============================================================================
# 06-access-and-test.sh
# IMPORTANT: RUN THIS SCRIPT ON YOUR LOCAL WORKSTATION (NOT INSIDE BASTION VM)!
#
# Provides and executes commands for:
#   1. SSH Tunnel into Bastion VM
#   2. Testing API, DNS, Node, and Ingress connections via Bastion
#   3. Configuring local /etc/hosts for private OpenShift Web Console
#   4. Starting HTTPS/HTTP Tunnel (127.0.0.2:443 & :80) to local machine
# ==============================================================================
set -euo pipefail

if [[ "$(hostname)" == *"-vm-bastion"* ]]; then
  echo "ERROR: 06-access-and-test.sh must be run on your LOCAL WORKSTATION, not inside the Bastion VM ($(hostname))."
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ ! -f "${REPO_ROOT}/config.env" ]]; then
  echo "ERROR: config.env not found. Please run ./scripts/00-prereq-config.sh first."
  exit 1
fi
# shellcheck source=/dev/null
source "${REPO_ROOT}/config.env"

CONSOLE_HOST="console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"
OAUTH_HOST="oauth-openshift.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"
CYMBAL_STOREFRONT_HOST="cymbal-storefront-cymbal-storefront.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"
CYMBAL_LEDGER_HOST="cymbal-ledger-cymbal-stateful.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"
API_HOST="api.${CLUSTER_NAME}.${BASE_DOMAIN}"
CONSOLE_LOCAL_IP="${CONSOLE_LOCAL_IP:-127.0.0.2}"

ACTION="${1:-print}"

print_commands() {
  cat <<EOF
==============================================================================
 1. SSH Tunnel Command to Bastion VM (Run from Local Machine)
==============================================================================
gcloud compute ssh ${BASTION_NAME} \\
  --project="${PROJECT_ID}" \\
  --zone="${ZONE}" \\
  --tunnel-through-iap

  Shortcut: ./scripts/06-access-and-test.sh ssh

==============================================================================
 2. Start / Restart / Delete OpenShift Installation (Run Inside Bastion VM)
==============================================================================
# Start installation:
~/ocp-setup/05-bastion-install-ocp.sh

# If installation fails — Destroy failed cluster & restart clean install:
~/ocp-setup/05-bastion-install-ocp.sh restart

# Or manually destroy & restart:
export GOOGLE_APPLICATION_CREDENTIALS=~/ocp-setup/${PREFIX}-sa-key.json
openshift-install destroy cluster --dir=~/ocp-cluster --log-level=info
rm -rf ~/ocp-cluster && mkdir -p ~/ocp-cluster
cp ~/ocp-setup/install-config.yaml.bak ~/ocp-cluster/install-config.yaml
openshift-install create cluster --dir=~/ocp-cluster --log-level=info

# Delete / destroy the cluster completely:
~/ocp-setup/05-bastion-install-ocp.sh destroy

==============================================================================
 3. Connection Test Commands (Run Inside Bastion VM or via 'test' subcommand)
==============================================================================
export KUBECONFIG=~/.kube/config
oc whoami
oc get nodes -o wide
oc get clusterversion
oc get co
curl -kI https://${API_HOST}:6443/healthz
curl -kI https://${CONSOLE_HOST}

  Shortcut from local machine: ./scripts/06-access-and-test.sh test

==============================================================================
 4. Local /etc/hosts Setup for Private Web Console & Phase 2 Cymbal Apps
    Uses ${CONSOLE_LOCAL_IP} so 127.0.0.1 remains free. All OpenShift Ingress
    routes (*.apps.${CLUSTER_NAME}.${BASE_DOMAIN}) share the same VIP and tunnel.
==============================================================================
sudo sh -c 'cat <<HOSTS >> /etc/hosts
${CONSOLE_LOCAL_IP} ${CONSOLE_HOST}
${CONSOLE_LOCAL_IP} ${OAUTH_HOST}
${CONSOLE_LOCAL_IP} ${CYMBAL_STOREFRONT_HOST}
${CONSOLE_LOCAL_IP} ${CYMBAL_LEDGER_HOST}
HOSTS'

  Shortcut: ./scripts/06-access-and-test.sh hosts

==============================================================================
 5. HTTPS/HTTP Tunnel to Local Machine for Web Console & Cymbal App Access
==============================================================================
# Note for macOS only: enable 127.0.0.2 on lo0 loopback interface first:
# sudo ifconfig lo0 alias ${CONSOLE_LOCAL_IP} up

sudo gcloud auth login
sudo gcloud compute ssh ${BASTION_NAME} \\
  --project="${PROJECT_ID}" \\
  --zone="${ZONE}" \\
  --tunnel-through-iap \\
  -- -N \\
  -L ${CONSOLE_LOCAL_IP}:443:${CONSOLE_HOST}:443 \\
  -L ${CONSOLE_LOCAL_IP}:80:${CONSOLE_HOST}:80

  Then open in your local browser:
    OpenShift Console : https://${CONSOLE_HOST}
    Cymbal Storefront : https://${CYMBAL_STOREFRONT_HOST}  (Phase 2 Option 1)
    Cymbal Ledger     : https://${CYMBAL_LEDGER_HOST}      (Phase 2 Option 2)

  Shortcut: ./scripts/06-access-and-test.sh tunnel
==============================================================================
EOF
}

case "${ACTION}" in
  print)
    print_commands
    ;;
  ssh)
    echo "Connecting to Bastion VM '${BASTION_NAME}' via IAP tunnel..."
    gcloud compute ssh "${BASTION_NAME}" \
      --project="${PROJECT_ID}" \
      --zone="${ZONE}" \
      --tunnel-through-iap
    ;;
  test)
    echo "Running connection and cluster health tests via Bastion '${BASTION_NAME}'..."
    gcloud compute ssh "${BASTION_NAME}" \
      --project="${PROJECT_ID}" \
      --zone="${ZONE}" \
      --tunnel-through-iap \
      --command="
        set -e
        export PATH=\"\$HOME/bin:\$PATH\"
        export KUBECONFIG=\"\$HOME/.kube/config\"
        echo '--- 1. Testing Private DNS Resolution ---'
        getent hosts ${API_HOST} ${CONSOLE_HOST} ${OAUTH_HOST} || true
        echo ''
        echo '--- 2. Testing OpenShift API Health (:6443) ---'
        curl -skI https://${API_HOST}:6443/healthz | head -n 5
        echo ''
        echo '--- 3. Testing OpenShift Web Console Ingress (:443) ---'
        curl -skI https://${CONSOLE_HOST} | head -n 5
        echo ''
        echo '--- 4. Checking Cluster Nodes & Version ---'
        oc get clusterversion
        oc get nodes -o wide
        echo ''
        echo '--- 5. Web Console Login Credentials ---'
        echo \"URL      : https://${CONSOLE_HOST}\"
        echo \"Username : kubeadmin\"
        if [[ -f \"\$HOME/ocp-cluster/auth/kubeadmin-password\" ]]; then
          echo \"Password : \$(cat \"\$HOME/ocp-cluster/auth/kubeadmin-password\")\"
        fi
      "
    ;;
  hosts)
    echo "Adding OpenShift Console, OAuth, and Phase 2 Cymbal App routes (${CONSOLE_LOCAL_IP}) to /etc/hosts (requires sudo)..."
    sudo sed -i.bak "/${CONSOLE_HOST}/d; /${OAUTH_HOST}/d; /${CYMBAL_STOREFRONT_HOST}/d; /${CYMBAL_LEDGER_HOST}/d" /etc/hosts
    sudo sh -c "cat <<HOSTS >> /etc/hosts
${CONSOLE_LOCAL_IP} ${CONSOLE_HOST}
${CONSOLE_LOCAL_IP} ${OAUTH_HOST}
${CONSOLE_LOCAL_IP} ${CYMBAL_STOREFRONT_HOST}
${CONSOLE_LOCAL_IP} ${CYMBAL_LEDGER_HOST}
HOSTS"
    echo "[UPDATED] Mapped ${CONSOLE_LOCAL_IP} ->"
    echo "  - ${CONSOLE_HOST}"
    echo "  - ${OAUTH_HOST}"
    echo "  - ${CYMBAL_STOREFRONT_HOST}"
    echo "  - ${CYMBAL_LEDGER_HOST}"
    if grep -qiE "(microsoft|wsl)" /proc/version 2>/dev/null; then
      echo ""
      echo "=============================================================================="
      echo " [WINDOWS WSL DETECTED] Additional Step for Windows Browsers (Chrome / Edge)"
      echo "=============================================================================="
      echo " Because your browser runs on Windows, you must ALSO add these hostnames to"
      echo " C:\\Windows\\System32\\drivers\\etc\\hosts."
      echo ""
      echo " Open PowerShell as Administrator on Windows and run:"
      echo "------------------------------------------------------------------------------"
      echo "Add-Content -Path C:\\Windows\\System32\\drivers\\etc\\hosts -Value \"\`r\`n${CONSOLE_LOCAL_IP} ${CONSOLE_HOST}\`r\`n${CONSOLE_LOCAL_IP} ${OAUTH_HOST}\`r\`n${CONSOLE_LOCAL_IP} ${CYMBAL_STOREFRONT_HOST}\`r\`n${CONSOLE_LOCAL_IP} ${CYMBAL_LEDGER_HOST}\""
      echo "------------------------------------------------------------------------------"
      echo " NOTE: On WSL2, ensure CONSOLE_LOCAL_IP=\"127.0.0.1\" in config.env (default on"
      echo " WSL) so Windows localhost forwarding reaches the WSL2 tunnel."
      echo "=============================================================================="
    fi
    ;;
  tunnel)
    if [[ "$(uname -s)" == "Darwin" ]]; then
      echo "macOS detected: Adding loopback alias ${CONSOLE_LOCAL_IP} to lo0..."
      sudo ifconfig lo0 alias "${CONSOLE_LOCAL_IP}" up
    fi
    echo "Starting HTTPS/HTTP Tunnel (Local ${CONSOLE_LOCAL_IP}:443 & :80 -> ${CONSOLE_HOST} via ${BASTION_NAME})..."
    echo "Open https://${CONSOLE_HOST} in your browser once connected."
    sudo gcloud compute ssh "${BASTION_NAME}" \
      --project="${PROJECT_ID}" \
      --zone="${ZONE}" \
      --tunnel-through-iap \
      -- -N \
      -L "${CONSOLE_LOCAL_IP}:443:${CONSOLE_HOST}:443" \
      -L "${CONSOLE_LOCAL_IP}:80:${CONSOLE_HOST}:80"
    ;;
  *)
    echo "Usage: $0 [print|ssh|test|hosts|tunnel]"
    exit 1
    ;;
esac
