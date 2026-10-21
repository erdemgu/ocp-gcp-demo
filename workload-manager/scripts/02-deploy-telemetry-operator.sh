#!/usr/bin/env bash
# ==============================================================================
# Phase 3 - Step 2: 02-deploy-telemetry-operator.sh
# Installs and configures the Cluster Services for OpenShift Telemetry Operator:
#   1. Applies OLM Subscription (google-cloud-cluster-services-for-openshift-telemetry)
#      in namespace 'openshift-operators' from 'certified-operators'
#   2. Waits for ClusterServiceVersion (CSV) to reach PHASE: Succeeded
#   3. Applies TelemetryConfig CR ('telemetryconfig') to start the telemetry daemon
#   4. Creates the 'workloadmanager' namespace and 'wlm-cluster-environment'
#      ConfigMap (environment: "production") and labels Phase 2 Cymbal workloads
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="${SCRIPT_DIR}/../manifests"

if [[ -f "${HOME}/ocp-setup/config.env" ]]; then
  # shellcheck source=/dev/null
  source "${HOME}/ocp-setup/config.env"
elif [[ -f "${SCRIPT_DIR}/../../config.env" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/../../config.env"
else
  echo "ERROR: config.env not found in ~/ocp-setup/ or repository root."
  exit 1
fi

export PATH="${HOME}/bin:${PATH}"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"

echo "=============================================================================="
echo " Phase 3 Step 2: Deploying Cluster Services for OpenShift Telemetry Operator"
echo "=============================================================================="

# Verify telemetry-agent-sa secret exists before deploying operator
if ! oc get secret telemetry-agent-sa -n openshift-operators >/dev/null 2>&1; then
  echo "ERROR: Secret 'telemetry-agent-sa' not found in namespace 'openshift-operators'."
  echo "       Please run ./scripts/01-prereq-wlm-iam.sh first."
  exit 1
fi

# 1. Apply OLM Subscription
echo "--- 1. Applying Subscription (google-cloud-cluster-services-for-openshift-telemetry) ---"
oc apply -f "${MANIFEST_DIR}/01-telemetry-subscription.yaml"

# 2. Wait for ClusterServiceVersion (CSV) to reach Succeeded
echo "--- 2. Waiting for Telemetry Operator CSV to reach PHASE: Succeeded (up to 4 mins) ---"
CSV_SUCCEEDED="false"
for ((i=1; i<=48; i++)); do
  CSV_LINE="$(oc get csv -n openshift-operators --no-headers 2>/dev/null | grep -E "cluster-services-for-openshift-telemetry" || true)"
  if echo "${CSV_LINE}" | grep -q "Succeeded"; then
    CSV_NAME="$(echo "${CSV_LINE}" | awk '{print $1}')"
    echo "[READY] Operator CSV '${CSV_NAME}' is Succeeded!"
    CSV_SUCCEEDED="true"
    break
  fi
  echo "  Waiting for CSV installation in openshift-operators (attempt ${i}/48)..."
  sleep 5
done

if [[ "${CSV_SUCCEEDED}" != "true" ]]; then
  echo "ERROR: Timed out waiting for Cluster Services for OpenShift Telemetry CSV to succeed."
  oc get sub,installplan,csv -n openshift-operators
  exit 1
fi

# 3. Apply TelemetryConfig Custom Resource
echo "--- 3. Applying TelemetryConfig ('telemetryconfig') to enable metrics collection ---"
oc apply -f "${MANIFEST_DIR}/02-telemetry-config.yaml"

echo "--- 4. Waiting for workloadagent-operator pod (telemetryconfig) to reach Running ---"
for ((i=1; i<=36; i++)); do
  POD_NAME="$(oc get pods -n openshift-operators \
    -l app.kubernetes.io/name=workloadagent-operator \
    --field-selector=status.phase=Running \
    -o=name 2>/dev/null | head -n 1 || true)"
  if [[ -n "${POD_NAME}" ]]; then
    echo "[READY] Telemetry agent pod '${POD_NAME}' is Running!"
    break
  fi
  echo "  Waiting for workloadagent-operator pod (attempt ${i}/36)..."
  sleep 5
done

# 5. Configure Workload Manager Production Evaluation Environment
echo "--- 5. Configuring Workload Manager Production Evaluation Tagging ---"
oc apply -f "${MANIFEST_DIR}/03-wlm-production-env.yaml"

# Optionally tag Phase 2 Cymbal workloads if deployed
if oc get deployment cymbal-storefront-web -n cymbal-storefront >/dev/null 2>&1; then
  oc label deployment cymbal-storefront-web -n cymbal-storefront environment=production --overwrite
  echo "  [TAGGED] Labeled deployment/cymbal-storefront-web (cymbal-storefront) with environment=production"
fi

if oc get deployment cymbal-ledger-ui -n cymbal-stateful >/dev/null 2>&1; then
  oc label deployment cymbal-ledger-ui -n cymbal-stateful environment=production --overwrite
  echo "  [TAGGED] Labeled deployment/cymbal-ledger-ui (cymbal-stateful) with environment=production"
fi

if oc get statefulset cymbal-ledger-db -n cymbal-stateful >/dev/null 2>&1; then
  oc label statefulset cymbal-ledger-db -n cymbal-stateful environment=production --overwrite
  echo "  [TAGGED] Labeled statefulset/cymbal-ledger-db (cymbal-stateful) with environment=production"
fi

echo ""
echo "=============================================================================="
echo " Cluster Services for OpenShift Telemetry Operator Deployed!"
echo " Next Step: ./scripts/03-trigger-and-verify.sh"
echo "=============================================================================="
