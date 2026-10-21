#!/usr/bin/env bash
# ==============================================================================
# Option 2 - Step 3: 03-deploy-cymbal-stateful.sh
# 1. Applies the Hyperdisk Balanced StorageClass (hyperdisk-balanced-csi)
# 2. Creates namespace 'cymbal-stateful' and renders SecretProviderClass
#    ('cymbal-gcp-secrets') connected to Google Cloud Secret Manager
# 3. Deploys Cymbal Order & Inventory Ledger PostgreSQL StatefulSet (20Gi
#    Hyperdisk Balanced PVC + Secret Manager CSI mount) and Web UI Route
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="${SCRIPT_DIR}/../manifests"

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

export PATH="${HOME}/bin:${PATH}"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"

echo "=============================================================================="
echo " Option 2 Step 3: Deploying Cymbal Stateful Ledger (Hyperdisk + Secret Manager)"
echo "=============================================================================="

# 1. Apply Hyperdisk Balanced StorageClass
echo "--- 1. Creating StorageClass 'hyperdisk-balanced-csi' ---"
oc apply -f "${MANIFEST_DIR}/01-hyperdisk-storageclass.yaml"

# 2. Create cymbal-stateful Namespace and apply SecretProviderClass
echo "--- 2. Creating namespace 'cymbal-stateful' and SecretProviderClass (tmpfs-only) ---"
oc create namespace cymbal-stateful --dry-run=client -o yaml | oc apply -f -

# Remove any legacy spec.secretObjects or etcd-synced cymbal-db-secret (WLM best practice)
oc delete secretproviderclass cymbal-gcp-secrets -n cymbal-stateful --ignore-not-found >/dev/null 2>&1 || true
oc delete secret cymbal-db-secret -n cymbal-stateful --ignore-not-found >/dev/null 2>&1 || true

python3 - "${MANIFEST_DIR}/04-secretproviderclass.yaml.tpl" << 'PYEOF' | oc apply -f -
import os, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    content = f.read()
for var in ("PROJECT_ID", "PREFIX"):
    content = content.replace(f"${{{var}}}", os.environ[var])
print(content)
PYEOF

# 3. Deploy Cymbal PostgreSQL StatefulSet (Hyperdisk) & Ledger UI
echo "--- 3. Deploying Cymbal PostgreSQL StatefulSet & Ledger Web UI ---"
oc apply -f "${MANIFEST_DIR}/05-cymbal-stateful-app.yaml"

echo "--- 4. Waiting for Cymbal PostgreSQL StatefulSet (Hyperdisk PVC + Secret Manager CSI) ---"
oc rollout status statefulset/cymbal-ledger-db -n cymbal-stateful --timeout=240s

echo "--- 5. Waiting for Cymbal Ledger Web UI Deployment ---"
oc rollout status deployment/cymbal-ledger-ui -n cymbal-stateful --timeout=180s

ROUTE_HOST="$(oc get route cymbal-ledger -n cymbal-stateful -o jsonpath='{.spec.host}')"

echo ""
echo "=============================================================================="
echo " Option 2: Cymbal Stateful Ledger (Hyperdisk + Secret Manager) Deployed!"
echo "=============================================================================="
oc get pvc,pods,route -n cymbal-stateful -o wide
echo ""
echo " Mounted Secret Manager Files inside PostgreSQL StatefulSet:"
oc exec -n cymbal-stateful statefulset/cymbal-ledger-db -- ls -la /mnt/secrets-store
echo ""
echo " Cymbal Ledger URL : https://${ROUTE_HOST}"
echo ""
echo " To access from your LOCAL WORKSTATION browser:"
echo "   1. On your Local Workstation, run: ./scripts/06-access-and-test.sh hosts"
echo "   2. Start the tunnel (if not running): ./scripts/06-access-and-test.sh tunnel"
echo "   3. Open: https://${ROUTE_HOST}"
echo "=============================================================================="
