# Phase 3 Step-by-Step Guide: Google Cloud Workload Manager & Cluster Services for OpenShift Telemetry Operator (Preview)

This guide walks through setting up the **Cluster Services for OpenShift Telemetry Operator** (`google-cloud-cluster-services-for-openshift-telemetry`) on your private Red Hat OpenShift 4.22 cluster on Google Cloud and evaluating your cluster in **Google Cloud Workload Manager**.

- **Official Documentation**: [Set up Cluster Services for OpenShift Telemetry Operator](https://docs.cloud.google.com/workload-manager/docs/evaluate/set-up-operator-for-openshift)
- **Supported OpenShift Versions**: OpenShift Container Platform 4.18 or later (our demo runs **OCP 4.22.16**).

> [!IMPORTANT]
> **Preview Feature Notice**: Google Cloud Workload Manager evaluations for Red Hat OpenShift and the **Cluster Services for OpenShift Telemetry Operator** (`google-cloud-cluster-services-for-openshift-telemetry`) are currently in **Preview** (Pre-GA) and subject to the "Pre-GA Offerings Terms" of the Google Cloud Terms of Service.

---

## 1. Prerequisites & Required Google Cloud APIs

The Telemetry Operator requires three Google Cloud APIs in your project (`${PROJECT_ID}`) and a dedicated Google Cloud Service Account (`${PREFIX}-wlm-telemetry-sa@${PROJECT_ID}.iam.gserviceaccount.com`) with three least-privilege IAM roles:

| Google Cloud API / IAM Role | Purpose |
| :--- | :--- |
| `workloadmanager.googleapis.com` | Enables Google Cloud Workload Manager evaluations and data warehouse ingestion. |
| `compute.googleapis.com` | Allows inspection of Compute Engine VM instances backing the OpenShift cluster. |
| `logging.googleapis.com` | Streams telemetry collection logs (`google-cloud-workload-agent`) to Cloud Logging. |
| `roles/compute.viewer` | Grants read-only access to Compute Engine instance metadata and disks. |
| `roles/workloadmanager.insightWriter` | Grants permission to write OpenShift cluster configuration insights to Workload Manager. |
| `roles/logging.logWriter` | Grants permission to write agent operational logs to Cloud Logging. |

---

## 2. Automated Deployment (Recommended)

### Step 1: Sync Phase 3 Scripts to the Bastion VM (On Local Workstation)
```bash
./workload-manager/sync-to-bastion.sh
./scripts/06-access-and-test.sh ssh
```

### Step 2: Configure GCP APIs, Service Account & Kubernetes Secret (On Bastion VM)
```bash
cd ~/ocp-setup/workload-manager
./scripts/01-prereq-wlm-iam.sh
```
**What this script does**:
1. Enables `workloadmanager.googleapis.com`, `compute.googleapis.com`, and `logging.googleapis.com`.
2. Creates `${PREFIX}-wlm-telemetry-sa@${PROJECT_ID}.iam.gserviceaccount.com`.
3. Binds `roles/compute.viewer`, `roles/workloadmanager.insightWriter`, and `roles/logging.logWriter`.
4. Creates the `telemetry-agent-sa` Secret in the `openshift-operators` namespace (`--from-file=workload_agent_sa_key.json=...`) and deletes the temporary JSON key from disk.

### Step 3: Install the Operator & Enable Telemetry Collection (On Bastion VM)
```bash
./scripts/02-deploy-telemetry-operator.sh
```
**What this script does**:
1. Applies [`manifests/01-telemetry-subscription.yaml`](../manifests/01-telemetry-subscription.yaml) to subscribe to `google-cloud-cluster-services-for-openshift-telemetry` (`stable` channel from `certified-operators` in `openshift-marketplace`).
2. Polls `oc get csv -n openshift-operators` until `cluster-services-for-openshift-telemetry` reaches `PHASE: Succeeded`.
3. Applies [`manifests/02-telemetry-config.yaml`](../manifests/02-telemetry-config.yaml) (`TelemetryConfig` `telemetryconfig` in `openshift-operators` with `imageVersion: latest`) to enable metrics collection using `telemetry-agent-sa`.
   > [!IMPORTANT]
   > **Why `imageVersion: latest` is Required**: Although the Preview documentation snippet omits `imageVersion`, the certified operator controller (`v0.0.7`) validates that `spec.imageVersion` is non-empty (`WorkloadAgent spec is invalid, cannot create instance: image version is empty`). Setting `imageVersion: latest` in [`manifests/02-telemetry-config.yaml`](../manifests/02-telemetry-config.yaml) resolves this and deploys the `telemetryconfig` (`workloadagent-operator`) pod cleanly.
4. Applies [`manifests/03-wlm-production-env.yaml`](../manifests/03-wlm-production-env.yaml) to create the `workloadmanager` namespace and `wlm-cluster-environment` ConfigMap (`environment: "production"`), and labels any deployed Phase 2 Cymbal workloads (`cymbal-storefront-web`, `cymbal-ledger-ui`, `cymbal-ledger-db`) with `environment=production`.

### Step 4: Trigger Immediate Metrics Collection & Verify (On Bastion VM)
By default, the telemetry operator collects metrics every **30 minutes**. Run `03-trigger-and-verify.sh` to verify the pod and trigger an immediate collection run:
```bash
./scripts/03-trigger-and-verify.sh
```
Under the hood, this locates the running `workloadagent-operator` pod and executes:
```bash
POD_NAME=$(oc get pods -n openshift-operators -l app.kubernetes.io/name=workloadagent-operator --field-selector=status.phase=Running -o=name)
oc debug -n openshift-operators -t $POD_NAME -- /openshift-docker-entrypoint.sh
```

---

## 3. Alternative Authentication: Workload Identity Federation (`ccoctl`)

If your organization uses **Workload Identity Federation (WIF)** instead of Service Account keys, you can provision WIF credentials using the OpenShift `ccoctl` utility:

```bash
# 1. Extract the CredentialsRequest manifest from the operator bundle:
mkdir -p credrequests
oc image extract us-docker.pkg.dev/workload-agent-products/cluster-services-for-openshift-telemetry/bundle:<VERSION> \
  --path /manifests/:./credrequests --confirm

# 2. Generate WIF resources and manifests with ccoctl:
ccoctl gcp create-all \
  --name=cso-telemetry \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --credentials-requests-dir=./credrequests \
  --output-dir=./ccoctl-out

# 3. Apply the generated secret manifests (creates google-cloud-cluster-services-telemetry-agent-wif-secret):
oc apply -f ./ccoctl-out/manifests/
```
When using WIF, omit `serviceAccountCredentialsSecretName` and `serviceAccountCredentialsPath` from `TelemetryConfig`:
```yaml
apiVersion: cluster-services-openshift.cloud.google.com/v1alpha1
kind: TelemetryConfig
metadata:
  name: telemetryconfig
  namespace: openshift-operators
spec:
  enabled: true
  imageVersion: latest
```

---

## 4. Installing via the OpenShift Web Console (UI Alternative)

Instead of running `02-deploy-telemetry-operator.sh`, you can also install the operator from the OpenShift Web Console:
1. Open the OpenShift Web Console (**Administrator** perspective) $\rightarrow$ **Operators** $\rightarrow$ **OperatorHub**.
2. Search for **Cluster Services for OpenShift Telemetry** (or filter by provider **Google**).
3. Click **Install** with:
   - **Update channel**: `stable`
   - **Installation mode**: `All namespaces on the cluster` (or `openshift-operators`)
   - **Approval Strategy**: `Automatic`
4. Wait for **Operators** $\rightarrow$ **Installed Operators** to show **Succeeded**, then create the `TelemetryConfig` instance (`telemetryconfig`).

---

## 5. Viewing Telemetry Logs & Running Evaluations in Google Cloud Console

1. **View Telemetry Operator Logs in Cloud Logging**:
   - In the Google Cloud Console, go to **Logging** $\rightarrow$ **Logs Explorer** and run:
     ```text
     logName="projects/<PROJECT_ID>/logs/google-cloud-workload-agent"
     ```
2. **Create & Run an OpenShift Evaluation in Workload Manager**:
   - Open [**Workload Manager** in the Google Cloud Console](https://console.cloud.google.com/workload-manager/evaluations).
   - Click **New evaluation**, select **OpenShift** as the workload type, choose your region and cluster instances, and run the evaluation to inspect best-practice compliance across compute, storage, network, and security rules.
