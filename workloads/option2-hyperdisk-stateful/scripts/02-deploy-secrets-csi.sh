#!/usr/bin/env bash
# ==============================================================================
# Option 2 - Step 2: 02-deploy-secrets-csi.sh
# 1. Installs the Secrets Store CSI Driver Operator in openshift-cluster-csi-drivers
# 2. Creates the ClusterCSIDriver (secrets-store.csi.k8s.io)
# 3. Provisions GCP credentials secret and OpenShift privileged SCC for the
#    Google Cloud Secrets Store CSI Provider
# 4. Deploys the GCP Provider DaemonSet (csi-secrets-store-provider-gcp)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="${SCRIPT_DIR}/../manifests"

if [[ -f "${HOME}/ocp-setup/config.env" ]]; then
  # shellcheck source=/dev/null
  source "${HOME}/ocp-setup/config.env"
  SA_KEY_PATH="${HOME}/ocp-setup/${PREFIX}-sa-key.json"
elif [[ -f "${SCRIPT_DIR}/../../../config.env" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/../../../config.env"
  SA_KEY_PATH="${SA_KEY_FILE}"
else
  echo "ERROR: config.env not found."
  exit 1
fi

export PATH="${HOME}/bin:${PATH}"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"

echo "=============================================================================="
echo " Option 2 Step 2: Deploying Secrets Store CSI Driver Operator & GCP Provider"
echo "=============================================================================="

# 1. Ensure an AllNamespaces OperatorGroup (spec: {}) exists in openshift-cluster-csi-drivers
#    Note: CSI driver operators in openshift-cluster-csi-drivers require AllNamespaces
#    InstallModeType (empty spec: {}) and do NOT support OwnNamespace (spec.targetNamespaces).
EXISTING_OG="$(oc get operatorgroup -n openshift-cluster-csi-drivers -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -z "${EXISTING_OG}" ]]; then
  echo "[CREATE] Creating AllNamespaces OperatorGroup in openshift-cluster-csi-drivers..."
  cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cluster-csi-drivers
  namespace: openshift-cluster-csi-drivers
spec: {}
EOF
else
  OG_TARGETS="$(oc get operatorgroup "${EXISTING_OG}" -n openshift-cluster-csi-drivers -o jsonpath='{.spec.targetNamespaces}' 2>/dev/null || true)"
  if [[ -n "${OG_TARGETS}" && "${OG_TARGETS}" != "[]" ]]; then
    echo "[FIX] OperatorGroup '${EXISTING_OG}' has targetNamespaces=${OG_TARGETS} (OwnNamespace mode)."
    echo "      Patching '${EXISTING_OG}' to AllNamespaces mode (spec: {})..."
    oc patch operatorgroup "${EXISTING_OG}" -n openshift-cluster-csi-drivers --type=merge -p '{"spec":{"targetNamespaces":null}}'
    # Remove any Failed CSVs so OLM re-creates them cleanly under AllNamespaces mode
    for csv in $(oc get csv -n openshift-cluster-csi-drivers --no-headers 2>/dev/null | awk '/Failed/ {print $1}'); do
      echo "      Deleting failed CSV '${csv}' to trigger clean OLM reinstall..."
      oc delete csv "${csv}" -n openshift-cluster-csi-drivers --ignore-not-found
    done
  else
    echo "[OK] Existing AllNamespaces OperatorGroup '${EXISTING_OG}' found in openshift-cluster-csi-drivers."
  fi
fi

# 2. Apply Secrets Store CSI Driver Operator Subscription & ClusterCSIDriver
echo "--- 1. Applying Secrets Store CSI Driver Operator & ClusterCSIDriver ---"
oc apply -f "${MANIFEST_DIR}/02-secrets-store-csi-operator.yaml"

echo "--- 2. Waiting for Secrets Store CSI Driver pods to start (up to 3 mins) ---"
for ((i=1; i<=36; i++)); do
  if oc get pods -n openshift-cluster-csi-drivers 2>/dev/null | grep -q " secrets-store-csi-driver-node-.*Running"; then
    echo "[READY] Secrets Store CSI Driver node pods are Running!"
    break
  fi
  echo "  Waiting for Secrets Store CSI Driver pods (attempt ${i}/36)..."
  sleep 5
done

# 3. Create GCP Credentials Secret & Grant OpenShift privileged SCC to Provider SA
echo "--- 3. Configuring GCP Provider Credentials & OpenShift Privileged SCC ---"
if [[ -f "${SA_KEY_PATH}" ]]; then
  oc create secret generic gcp-secrets-store-cloud-credentials \
    -n openshift-cluster-csi-drivers \
    --from-file=service_account.json="${SA_KEY_PATH}" \
    --dry-run=client -o yaml | oc apply -f -
else
  echo "ERROR: Service Account key file not found at ${SA_KEY_PATH}"
  exit 1
fi

oc adm policy add-scc-to-user privileged \
  -z csi-secrets-store-provider-gcp-sa \
  -n openshift-cluster-csi-drivers

# 4. Deploy Google Cloud Provider DaemonSet
echo "--- 4. Deploying Google Cloud Provider for Secrets Store CSI Driver ---"
oc apply -f "${MANIFEST_DIR}/03-gcp-csi-provider.yaml"
oc rollout status daemonset/csi-secrets-store-provider-gcp -n openshift-cluster-csi-drivers --timeout=180s

echo ""
echo "=============================================================================="
echo " Secrets Store CSI Driver Operator & GCP Provider Ready!"
echo "=============================================================================="
oc get pods -n openshift-cluster-csi-drivers -l app=csi-secrets-store-provider-gcp
echo ""
echo "Next Step: ./scripts/03-deploy-cymbal-stateful.sh"
