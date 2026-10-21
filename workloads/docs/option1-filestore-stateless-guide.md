# Option 1 Guide: Stateless Cymbal Storefront with Regional Private Cloud Filestore

This step-by-step guide walks through deploying **Option 1**: a multi-replica stateless **Google Cloud Cymbal Retail Storefront** application integrated with a **regional, private Google Cloud Filestore** instance using the **GCP Filestore CSI Driver Operator** on OpenShift 4.22.

---

## Prerequisites

1. Your Phase 1 private OpenShift 4.22 cluster is installed and healthy (`oc get nodes` and `oc get co`).
2. `~/ocp-setup/config.env` is present on the Bastion VM (synced via `./workloads/sync-to-bastion.sh` from your local workstation).

---

## Step 1: Sync Workloads to Bastion & SSH In

On your **Local Workstation**, sync the `workloads/` folder to the Bastion VM and open an SSH session:

```bash
./workloads/sync-to-bastion.sh
source config.env
gcloud compute ssh "${BASTION_NAME}" \
  --project="${PROJECT_ID}" \
  --zone="${ZONE}" \
  --tunnel-through-iap
```

---

## Step 2: Configure Private Service Access & Filestore Prerequisites (`01-prereq-filestore-psa.sh`)

> [!IMPORTANT]
> **Execution Location: BASTION VM**

Regional Cloud Filestore (`Enterprise` tier) connects privately to your custom VPC (`${PREFIX}-vpc`) using **Google Cloud Private Service Access (PSA)** over VPC Network Peering.

Inside the **Bastion VM**, run:

```bash
cd ~/ocp-setup/workloads/option1-filestore-stateless
./scripts/01-prereq-filestore-psa.sh
```

What this script does:
1. Enables `file.googleapis.com` (Cloud Filestore API) and `servicenetworking.googleapis.com` (Service Networking API) on `${PROJECT_ID}`.
2. Grants `roles/file.editor` and `roles/servicenetworking.networksAdmin` to `${SA_EMAIL}`.
3. Allocates an internal `/20` IP range (`${PREFIX}-psa-range`) in `${VPC_NAME}` for `VPC_PEERING`.
4. Establishes the `servicenetworking.googleapis.com` VPC peering connection on `${VPC_NAME}`.
   *(Note: The `gcp-filestore-cloud-credentials` secret in `openshift-cluster-csi-drivers` is automatically minted by OpenShift's Cloud Credential Operator when the CSI operator is installed in Step 3).*

---

## Step 3: Deploy the GCP Filestore CSI Driver Operator & Regional StorageClass (`02-deploy-filestore-csi.sh`)

> [!IMPORTANT]
> **Execution Location: BASTION VM**

Inside the **Bastion VM**, run:

```bash
./scripts/02-deploy-filestore-csi.sh
```

What this script does:
1. Installs the **GCP Filestore CSI Driver Operator** (`gcp-filestore-csi-driver-operator`) in `openshift-cluster-csi-drivers` from the Red Hat Operators catalog.
2. Waits for the operator CSV to succeed and creates the `ClusterCSIDriver` resource (`filestore.csi.storage.gke.io`).
3. Creates the regional `StorageClass` named **`filestore-regional-csi`**:
   - `provisioner: filestore.csi.storage.gke.io`
   - `tier: enterprise` (Regional multi-zone high-availability Filestore tier)
   - `network: projects/${PROJECT_ID}/global/networks/${VPC_NAME}`
   - `connect-mode: PRIVATE_SERVICE_ACCESS`

Verify the CSI driver pods and StorageClass:
```bash
oc get pods -n openshift-cluster-csi-drivers -l app=gcp-filestore-csi-driver-controller
oc get sc filestore-regional-csi
```

---

## Step 4: Deploy the Cymbal Retail Storefront Stateless Workload (`03-deploy-cymbal-stateless.sh`)

> [!IMPORTANT]
> **Execution Location: BASTION VM**

Inside the **Bastion VM**, run:

```bash
./scripts/03-deploy-cymbal-stateless.sh
```

What this script does:
1. Creates the `cymbal-storefront` namespace and the `1Ti` `ReadWriteMany` (`RWX`) `PersistentVolumeClaim` (`cymbal-shared-assets-pvc`) using `storageClassName: filestore-regional-csi`.
   - *Note*: Provisioning a new regional Enterprise Cloud Filestore instance in Google Cloud typically takes **10–15 minutes**. The script monitors the PVC status until it reaches `Bound`.
2. Deploys the 3-replica stateless **Cymbal Retail Storefront** (`cymbal-storefront-web`), `Service` (`cymbal-storefront-svc`), and TLS Edge `Route` (`cymbal-storefront`).
3. All 3 stateless pods mount the shared Regional Filestore NFS volume at `/mnt/cymbal-filestore` (`ReadWriteMany`).

---

## Step 5: Test & Access the Cymbal Retail Storefront in Your Browser

### 5.1 Verify from Bastion VM
```bash
oc get pvc -n cymbal-storefront
oc get pods -n cymbal-storefront -o wide
ROUTE_HOST=$(oc get route cymbal-storefront -n cymbal-storefront -o jsonpath='{.spec.host}')
curl -k https://${ROUTE_HOST}
```

### 5.2 Open in Local Browser (Run on Local Workstation)
On your **Local Workstation**, run `./scripts/06-access-and-test.sh hosts` (which automatically detects deployed Phase 2 routes and maps them to `127.0.0.2` in `/etc/hosts`) and start the tunnel:

```bash
./scripts/06-access-and-test.sh hosts
./scripts/06-access-and-test.sh tunnel
```

Then open in your browser:
- `https://cymbal-storefront-cymbal-storefront.apps.<CLUSTER_NAME>.<BASE_DOMAIN>`

The page **auto-refreshes every 3 seconds**, rotating the active serving **Pod and Worker Node** in round-robin order while all 3 active replicas read and write to the same shared Regional Cloud Filestore NFS mount (`/mnt/cymbal-filestore`).

### 5.3 How the Shared Filestore Volume Works & Live Demo Verification

All 3 stateless replicas mount the `cymbal-shared-assets-pvc` (`ReadWriteMany` Regional Cloud Filestore NFS share) at `/mnt/cymbal-filestore`:
1. **Initial Seed (`ensure_shared_files()`)**: When the first pod starts, if `/mnt/cymbal-filestore/cymbal-catalog.json` does not exist yet on the Filestore share, it writes the initial product catalog JSON file to `/mnt/cymbal-filestore/cymbal-catalog.json`.
2. **Live Read on Every Refresh (`do_GET`)**: On every 3-second page refresh, the serving pod reads `/mnt/cymbal-filestore/cymbal-catalog.json`, `/mnt/cymbal-filestore/pod-registry.json`, and `/mnt/cymbal-filestore/storefront-access.log` directly from the Regional Cloud Filestore NFS mount.

#### Live Proof During a Demo (Run on Bastion VM)
You can prove live `ReadWriteMany` NFS sharing across all worker nodes by modifying `/mnt/cymbal-filestore/cymbal-catalog.json` inside **only one pod**—within 3 seconds, **all 3 pods** across every worker node will immediately display the new item:

```bash
# 1. Inspect the Cloud Filestore NFS mount and shared files from any pod:
oc exec -n cymbal-storefront deploy/cymbal-storefront-web -- df -hT /mnt/cymbal-filestore
oc exec -n cymbal-storefront deploy/cymbal-storefront-web -- ls -lh /mnt/cymbal-filestore

# 2. Add a 5th product to /mnt/cymbal-filestore/cymbal-catalog.json from a single pod:
oc exec -n cymbal-storefront deploy/cymbal-storefront-web -- python3 -c '
import json
path = "/mnt/cymbal-filestore/cymbal-catalog.json"
data = json.load(open(path))
data.append({
    "sku": "CYM-999",
    "name": "Cymbal AI Workstation Dock (Live Filestore Edit)",
    "price": "$299.00",
    "category": "Accessories",
    "stock": "Just Added via NFS!"
})
json.dump(data, open(path, "w"), indent=2)
'
```
Watch your browser auto-refresh 3 seconds later: every pod on every worker node immediately serves `CYM-999` from the shared Cloud Filestore file.

---

## Cleanup (Option 1 Only)

To remove the Option 1 Cymbal Storefront workload and dynamically provisioned Cloud Filestore instance (so you do not incur ongoing Filestore Enterprise charges), run on the **Bastion VM**:

```bash
cd ~/ocp-setup/workloads/option1-filestore-stateless
./scripts/04-cleanup-option1.sh
```
