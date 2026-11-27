# Live Demo Script & Presenter Guide: Red Hat OpenShift on Google Cloud

This guide provides a structured, step-by-step **live demonstration script** (~20–30 minutes) for showcasing a **Private, Multi-Zone Red Hat OpenShift 4.22 Self-Managed Cluster on Google Cloud** with **Custom N4 Compute + Hyperdisk Balanced**, **Regional Cloud Filestore (`ReadWriteMany`)**, **Google Cloud Secret Manager (`tmpfs` CSI)**, and **Google Cloud Workload Manager (Preview)**.

> [!TIP]
> **Audience Focus**: Tie every technical step back to the five business pillars—**Enterprise Security** (100% private cluster), **High Availability** (multi-zone), **Lower TCO** (custom N4 + Hyperdisk + VM stop/start), **Cloud-Native Managed Services** (Filestore + Secret Manager), and **Continuous Governance** (Workload Manager).

---

## Pre-Demo Preparation (10–15 Minutes Before Presenting)

Run these commands on your **Local Workstation** to ensure the cluster is running, healthy, and reachable in your browser:

### 1. Start the Cluster & Bastion VMs (If Stopped)
```bash
# Check current VM power status
./scripts/08-stop-start-vms.sh status

# Start Bastion -> Control Plane Masters -> Workers & auto-approve pending CSRs
./scripts/08-stop-start-vms.sh start
```

### 2. Verify Cluster Health & Print Credentials
```bash
# Verify private DNS, API health (:6443), Console (:443), and all 6 nodes Ready
./scripts/06-access-and-test.sh test
```
*(Optional: To retrieve the `kubeadmin` password from the Bastion VM)*:
```bash
source config.env
gcloud compute ssh "${BASTION_NAME}" --project="${PROJECT_ID}" --zone="${ZONE}" --tunnel-through-iap \
  --command="cat ~/ocp-cluster/auth/kubeadmin-password"
```

### 3. Configure Local Hosts & Open the IAP HTTPS Tunnel
```bash
# Map OpenShift Console, OAuth, and Cymbal app hostnames to 127.0.0.2 (or 127.0.0.1 on WSL)
./scripts/06-access-and-test.sh hosts

# Keep this terminal open during the demo
./scripts/06-access-and-test.sh tunnel
```

### 4. Pre-Open Browser Tabs
Open these 5 tabs before starting the demo so transitions are seamless:
1. **Google Cloud Console — Compute Engine VM Instances** (filtered by your `${PREFIX}`)
2. **OpenShift Web Console** (`https://console-openshift-console.apps.<CLUSTER_NAME>.<BASE_DOMAIN>`) — logged in as `kubeadmin`
3. **Phase 2 Option 1 — Cymbal Retail Storefront** (`https://cymbal-storefront-cymbal-storefront.apps.<CLUSTER_NAME>.<BASE_DOMAIN>`)
4. **Phase 2 Option 2 — Cymbal Order & Inventory Ledger** (`https://cymbal-ledger-cymbal-stateful.apps.<CLUSTER_NAME>.<BASE_DOMAIN>`)
5. **Google Cloud Console — Workload Manager Evaluations** (`https://console.cloud.google.com/workload-manager/evaluations`)

---

## Demo Flow Overview

| Segment | Duration | What You Show | Business Value Highlight |
| :--- | :--- | :--- | :--- |
| **Part 1: Private Multi-Zone Cluster & Cost-Optimized Sizing** | 5–7 min | GCP Console (0 External IPs, 3 Zones, N4 Custom + Hyperdisk) + OpenShift Console | **Security, HA & Lower TCO** |
| **Part 2: Stateless App + Regional Cloud Filestore (`RWX`)** | 5–7 min | 3-replica Cymbal Storefront rotating pods every 3s + live NFS catalog edit across zones | **Multi-Zone Shared Storage** |
| **Part 3: Stateful PostgreSQL + Hyperdisk + Secret Manager** | 5–7 min | Live order insert on Hyperdisk Balanced + `tmpfs`-only Secret Manager mount (no `etcd` secrets) | **Stateful Performance & Zero-Trust Secrets** |
| **Part 4: Google Cloud Workload Manager (Preview)** | 5 min | Automated OpenShift telemetry operator + best-practice compliance evaluation report | **Compliance & Security Governance** |

---

## Part 1: Private Multi-Zone OpenShift & Custom Sizing (5–7 Minutes)

### Step 1.1 — Show Zero Public Exposure & Multi-Zone Footprint (GCP Console)
1. Switch to **Tab 1 (GCP Compute Engine $\rightarrow$ VM Instances)**.
2. Point out:
   - **External IP column is empty (`None`)** for all 3 Masters, all 3 Workers, and the Bastion VM (`publish: Internal`).
   - **Multi-Zone distribution**: `master-0/1/2` and `worker-a/b/c` span zones `-a`, `-b`, and `-c`.
   - **Right-Sized Custom Compute + Hyperdisk**: Workers run **`n4-custom-6-20480`** (6 vCPU, 20 GB RAM) backed by **`hyperdisk-balanced`**, avoiding over-provisioning while delivering high IOPS/throughput.
3. Briefly note outbound internet traffic flows only through **Cloud NAT**, and administrative access uses **Cloud IAP** (no public SSH or public API/Console endpoints).

### Step 1.2 — Show OpenShift Cluster Health (OpenShift Console & Bastion CLI)
1. Switch to **Tab 2 (OpenShift Web Console $\rightarrow$ Home $\rightarrow$ Overview)**.
2. Highlight:
   - **OpenShift 4.22.16** on **GCP** with all Cluster Operators healthy and **6 Nodes** ready.
   - Navigate to **Compute $\rightarrow$ Nodes** (or **Storage $\rightarrow$ StorageClasses**) to show `filestore-regional-csi` and `hyperdisk-balanced-csi`.
3. *(Optional Bastion CLI proof)*:
   ```bash
   oc get nodes -L topology.kubernetes.io/zone,node.kubernetes.io/instance-type
   oc get sc
   ```

---

## Part 2: Stateless Multi-Zone Web Tier + Regional Cloud Filestore (`RWX`) (5–7 Minutes)

### Step 2.1 — Show Multi-Pod Round-Robin Rotation Sharing Regional Filestore
1. Switch to **Tab 3 (Cymbal Retail Storefront)**.
2. Watch the page **auto-refresh every 3 seconds**:
   - Point out the top cards rotating the **Serving Stateless Pod** and **OpenShift Worker Node** (`worker-a` $\rightarrow$ `worker-b` $\rightarrow$ `worker-c`) across all 3 availability zones.
   - Scroll to the **Live Multi-Pod Shared Access Log** at the bottom—every pod appends to the exact same file (`/mnt/cymbal-filestore/storefront-access.log`) on **Regional Enterprise Cloud Filestore** (`ReadWriteMany`).

### Step 2.2 — Live Demo: Edit Shared Catalog on One Pod, See Instantly on All 3 Pods
Inside the **Bastion VM**, inject a new product row into the shared Filestore catalog from **Pod 1**:
```bash
POD1=$(oc get pods -n cymbal-storefront -l app=cymbal-storefront-web -o jsonpath='{.items[0].metadata.name}')
oc exec -n cymbal-storefront "${POD1}" -- bash -c '
  echo "CYM-999|Cymbal AI Workstation Dock (Live Filestore Edit)|Accessories|\$299.00|Just Added via NFS!" >> /mnt/cymbal-filestore/catalog.csv
'
```
- Return to **Tab 3**: on the next 3-second refresh, **all 3 pods across zones `-a`, `-b`, and `-c`** immediately display `CYM-999` from the shared Regional Filestore volume.

---

## Part 3: Stateful PostgreSQL on Hyperdisk Balanced + Secret Manager CSI (5–7 Minutes)

### Step 3.1 — Show Live Transactional Persistence on Hyperdisk Balanced
1. Switch to **Tab 4 (Cymbal Order & Inventory Ledger)**.
2. Point out the three status cards at the top:
   - **StatefulSet & Block Storage**: `cymbal-ledger-db-0` backed by `20Gi hyperdisk-balanced-csi` (`ReadWriteOnce`).
   - **Secrets Store CSI Mount**: `/mnt/secrets-store` (`cymbal-api-key.txt`, `db-password.txt`).
   - **GCP Secret Manager API Key**: Masked live secret verified via CSI.
3. Click **`+ Record New Order on Hyperdisk`** once or twice to insert new orders live into PostgreSQL 16.

### Step 3.2 — Prove Zero `etcd` Secret Storage (`tmpfs`-Only Mount)
Inside the **Bastion VM**, show that credentials live **only in pod `tmpfs` memory** (and never as native Kubernetes `Secret` objects in `etcd`):
```bash
# 1. Confirm secrets are mounted in-memory inside the PostgreSQL StatefulSet pod:
oc exec -n cymbal-stateful statefulset/cymbal-ledger-db -- ls -la /mnt/secrets-store

# 2. Confirm no cymbal-db-secret exists in etcd (compliant with Workload Manager best practices):
oc get secret cymbal-db-secret -n cymbal-stateful || echo "Confirmed: No native etcd Secret exists!"

# 3. Confirm the 20Gi Hyperdisk Balanced PVC is Bound:
oc get pvc -n cymbal-stateful
```

---

## Part 4: Google Cloud Workload Manager Governance & Compliance (Preview) (5 Minutes)

> [!NOTE]
> Remind the audience that **Google Cloud Workload Manager for OpenShift** and the **Cluster Services for OpenShift Telemetry Operator** are currently in **Preview**.

### Step 4.1 — Show the Telemetry Operator & Evaluation Report
1. Switch to **Tab 5 (Google Cloud Console $\rightarrow$ Workload Manager $\rightarrow$ Evaluations)** and open your OpenShift evaluation report.
2. Highlight the **Passed** rules directly validated by our architecture:
   - **Control Plane Multi-Zonal Distribution** — Passed (3 masters across zones `-a`, `-b`, `-c`).
   - **Google Cloud Filestore for Shared Storage** & **Recommend Filestore Regional over Zonal Tier** — Passed (`enterprise` tier regional Filestore).
   - **Google Cloud Managed Block Storage** — Passed (`hyperdisk-balanced-csi`).
   - **Google Cloud Secret Manager Integration** & **Disallow `ALLOW_NODE_PUBLISH_SECRET` / `etcd` Secret Sync** — Passed (`tmpfs`-only `SecretProviderClass`).
   - **OpenShift Environment Labeling (Production/Non-Production)** — Passed (`workloadmanager` ConfigMap + `environment=production` labels).
3. Point out the remaining **Informational/Warning** recommendations (e.g., Workload Identity Federation, CMEK for Block Storage, Google Managed Prometheus) as concrete next-step enterprise hardening conversations.

### Step 4.2 — *(Optional)* Trigger Live Telemetry Collection from Bastion
```bash
~/ocp-setup/workload-manager/scripts/03-trigger-and-verify.sh
```

---

## Post-Demo Cost Optimization (Pause or Teardown)

When the demo finishes, **stop the cluster and Bastion VMs** to pause compute billing while keeping the cluster ready for your next presentation:

```bash
# Gracefully stop Workers -> Control Plane Masters -> Bastion VM
./scripts/08-stop-start-vms.sh stop
```

Or, to permanently destroy all demo resources (cluster, Bastion, Filestore, PSA peering, VPC, Secrets, and Service Accounts):
```bash
./scripts/07-cleanup.sh
```
