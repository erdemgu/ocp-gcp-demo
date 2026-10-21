# Step-by-Step Deployment Guide: OpenShift Self-Managed on Google Cloud

Follow this step-by-step guide to deploy your private Red Hat OpenShift Container Platform (OCP) cluster on Google Cloud from start to finish.

---

## Prerequisites Checklist

Before running the scripts, ensure you have:
1. **Google Cloud Project**: An existing GCP project with Billing enabled and Organization Policy Admin (`roles/orgpolicy.policyAdmin`) + Project Owner (`roles/owner`) permissions.
2. **Red Hat Account & Pull Secret**:
   - Log in to the [Red Hat OpenShift Pull Secret page](https://console.redhat.com/openshift/install/pull-secret).
   - Click **Download pull secret** and save it locally (e.g., `./pull-secret.txt` or `~/pull-secret.txt`).
   - *Note*: If you or your organization don't have an active Red Hat subscription, you can open a Red Hat account for free and use the **60-day trial license** for the deployment.
3. **`gcloud` CLI Authenticated**:
   ```bash
   gcloud auth login
   ```

---

## Step 0: Configure Prerequisites & Environment (`00-prereq-config.sh`)

From your local workstation, navigate to the repository root and run the interactive configuration script:

```bash
cd ocp-gcp-demo
./scripts/00-prereq-config.sh
```

You will be prompted for:
- **Existing GCP Project ID** (e.g., `my-gcp-project-id`)
- **GCP Region** (e.g., `us-central1`) and **Zone** (e.g., `us-central1-a`)
- **Naming Prefix** (e.g., `ocp-demo`) — applied to all resources
- **Private Local Domain** (defaults to `${PREFIX}.openshiftapps.local`, e.g., `ocp-demo.openshiftapps.local`)
- **VPC IP Range (`/20`)** (e.g., `10.90.32.0/20`) — automatically splits into:
  - Control Plane Subnet (`/23`): `10.90.32.0/23`
  - Worker Subnet (`/23`): `10.90.34.0/23`
  - Bastion Subnet (`/24`): `10.90.36.0/24`
- **Pull Secret File Path** (e.g., `./pull-secret.txt`)
- **Google Cloud Marketplace Offering Confirmation & Option** (optional — see note below)

### Note: Using a Google Cloud Marketplace Offering

For details, see [Red Hat Docs: Specifying a Google Cloud Marketplace image](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/installing_on_google_cloud/installing-gcp-customizations#installation-gcp-marketplace_installing-gcp-customizations).

> [!IMPORTANT]
> **Changing the OpenShift Version**: If you change the OpenShift version from `4.22.16` to another version, check the [Red Hat Google Cloud Marketplace image documentation](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/installing_on_google_cloud/installing-gcp-customizations#installation-gcp-marketplace_installing-gcp-customizations) for that version's corresponding Marketplace image ID and update `osImage.name` (`MARKETPLACE_IMAGE_NAME`) accordingly.

#### Prerequisites
- You have an existing `install-config.yaml` file.

#### Procedure
During `./scripts/00-prereq-config.sh` (or by editing `install-config.yaml` directly before running `openshift-install`), you can configure `compute.platform.gcp.osImage` and `controlPlane.platform.gcp.osImage` to specify the location of the Google Cloud Marketplace image for both worker and master nodes:
1. Set the `project` parameter to `redhat-marketplace-public`.
2. Set the `name` parameter to one of the following offers:
   - **OpenShift Container Platform**: `redhat-coreos-ocp-413-x86-64-202305021736`
   - **OpenShift Platform Plus**: `redhat-coreos-opp-413-x86-64-202305021736`
   - **OpenShift Kubernetes Engine**: `redhat-coreos-oke-413-x86-64-202305021736`
3. Save the file and reference it when deploying the cluster.

Sample `install-config.yaml` specifying a Google Cloud Marketplace image for both worker (`compute`) and master (`controlPlane`) machines:
```yaml
apiVersion: v1
baseDomain: example.com
compute:
- architecture: amd64
  hyperthreading: Enabled
  name: worker
  replicas: 3
  platform:
    gcp:
      type: n4-custom-6-20480
      osDisk:
        diskType: hyperdisk-balanced
        diskSizeGB: 200
      osImage:
        project: redhat-marketplace-public
        name: redhat-coreos-ocp-413-x86-64-202305021736
controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  replicas: 3
  platform:
    gcp:
      type: e2-standard-4
      osDisk:
        diskType: pd-ssd
        diskSizeGB: 100
      osImage:
        project: redhat-marketplace-public
        name: redhat-coreos-ocp-413-x86-64-202305021736
# ...
```

**Output**: Generates `config.env` and copies the validated pull secret into `generated/pull-secret.txt`.

---

## Step 1: Check & Configure Organization Policies (`01-policy-check.sh`)

Run the policy check script to enable all required GCP APIs and configure the Organization Policies (`iam.disableServiceAccountKeyCreation`, `iam.managed.disableServiceAccountKeyCreation`, `iam.disableServiceAccountCreation`, `iam.managed.disableServiceAccountCreation`, and `compute.trustedImageProjects`):

> [!NOTE]
> Domain Restricted Sharing (`iam.allowedPolicyMemberDomains`) does **not** need to be relaxed (`allowAll: true` is not required) because Self-Managed OCP only creates and binds IAM roles to service accounts inside your own GCP project (`@${PROJECT_ID}.iam.gserviceaccount.com`) and does not add `@redhat.com` accounts to GCP IAM.

```bash
./scripts/01-policy-check.sh
```

> [!TIP]
> Wait approximately 30–60 seconds after this step completes to ensure Organization Policy overrides have propagated across IAM before creating service account keys.

---

## Step 2: Deploy VPC, 3 Subnets & Cloud NAT (`02-vpc-setup.sh`)

Deploy the custom VPC (`${PREFIX}-vpc`), the three subnets (`control-plane`, `worker`, and `bastion`), the Cloud Router + Cloud NAT gateway for outbound internet connectivity, and the IAP/internal firewall rules:

```bash
./scripts/02-vpc-setup.sh
```

---

## Step 3: Create SSH Key & OCP Service Account (`03-iam-and-keys.sh`)

Generate the Ed25519 SSH key pair (`generated/${PREFIX}-ssh`), create the OpenShift Service Account (`${PREFIX}-ocp-sa`), bind the required IAM roles, and download the JSON key (`generated/${PREFIX}-sa-key.json`):

```bash
./scripts/03-iam-and-keys.sh
```

---

## Step 4: Provision Bastion VM & Copy Installation Files (`04-bastion-setup.sh`)

Render `generated/install-config.yaml` (preserving the custom `n4-custom-6-20480` worker shape with `hyperdisk-balanced` and `e2-standard-4` control plane shape), deploy the private Debian 13 Bastion VM (`${PREFIX}-vm-bastion`), and copy all installation artifacts to `~/ocp-setup/` on the Bastion:

```bash
./scripts/04-bastion-setup.sh
```

### Customizing VM Sizes, Replicas, and Disk Types in `install-config.yaml`

You can change the VM machine types, vCPU/memory shapes, replica counts, or boot disk types either:
- **Option A (Local Template)**: Edit `templates/install-config.yaml.tpl` before running `./scripts/04-bastion-setup.sh`.
- **Option B (On Bastion VM)**: After SSHing into the Bastion VM (and before running `~/ocp-setup/05-bastion-install-ocp.sh`), edit `~/ocp-setup/install-config.yaml`:
  ```bash
  vi ~/ocp-setup/install-config.yaml
  ```

#### Key Fields to Edit in `install-config.yaml`:
```yaml
compute:
- architecture: amd64
  hyperthreading: Enabled
  name: worker
  replicas: 3                        # Change worker node count (minimum 2, default 3)
  platform:
    gcp:
      type: n4-custom-6-20480        # Change worker machine type (see compatibility table below)
      osDisk:
        diskType: hyperdisk-balanced # Disk type: hyperdisk-balanced (for N4) or pd-ssd / pd-balanced (for E2/N2)
        diskSizeGB: 200              # Worker boot disk size in GB
controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  replicas: 3                        # Control plane count (3 for HA)
  platform:
    gcp:
      type: e2-standard-4            # Change master machine type (e.g., e2-standard-8, n2-standard-4)
      osDisk:
        diskType: pd-ssd             # Disk type: pd-ssd (recommended for etcd on E2/N2) or hyperdisk-balanced (for N4)
        diskSizeGB: 100              # Control plane boot disk size in GB
```

#### Machine Type & Disk Compatibility Reference
| Machine Series | Example `type` Values | Supported `diskType` Values | Notes |
| :--- | :--- | :--- | :--- |
| **N4 (Standard or Custom)** | `n4-custom-6-20480`, `n4-standard-4`, `n4-standard-8` | `hyperdisk-balanced` | Custom format: `n4-custom-<vCPUs>-<MemoryMB>`. Requires `hyperdisk-balanced` (`pd-ssd` is not supported on N4). |
| **N2 / N2D** | `n2-standard-4`, `n2-standard-8`, `n2-custom-6-20480` | `pd-ssd`, `pd-balanced` | General-purpose Intel/AMD; supports both standard shapes and custom `<vCPUs>-<MemoryMB>`. |
| **E2** | `e2-standard-4`, `e2-standard-8`, `e2-custom-6-20480` | `pd-ssd`, `pd-balanced` | Cost-optimized; use `pd-ssd` when running control plane (`etcd`) on E2. |

> [!NOTE]
> **Multi-Zone Architecture**: This cluster is deployed with a **multi-zone architecture**. The 3 Control Plane nodes and 3 Worker `MachineSet`s (`worker-a`, `worker-b`, `worker-c`) are automatically distributed across multiple availability zones (`-a`, `-b`, `-c`) in your selected region for high availability. When customizing machine types, verify that the chosen machine series is available across the zones in your target region.

---

## Step 5: SSH to Bastion & Start OpenShift Installation Manually (`05-bastion-install-ocp.sh` — Runs on Bastion VM)

> [!IMPORTANT]
> **Execution Location: BASTION VM ONLY**
> `05-bastion-install-ocp.sh` must be executed **inside the Bastion VM** (`~/ocp-setup/05-bastion-install-ocp.sh`), **not** on your local workstation.

### 5.1 SSH into the Bastion VM via IAP Tunnel (From Local Workstation)
Copy and run the `gcloud compute ssh` command printed at the end of Step 4 (`04-bastion-setup.sh`), or run on your **Local Workstation**:

```bash
source config.env
gcloud compute ssh "${BASTION_NAME}" \
  --project="${PROJECT_ID}" \
  --zone="${ZONE}" \
  --tunnel-through-iap
```

### 5.2 Start the Installation (Inside the Bastion VM)
Once logged into the **Bastion VM**, run:

```bash
~/ocp-setup/05-bastion-install-ocp.sh
```

What `05-bastion-install-ocp.sh` does on the Bastion:
1. Installs `wget`, `tar`, `jq`, `httpd-tools` (`htpasswd`), and `bind-utils`.
2. Downloads OpenShift **4.22.16** (`openshift-install`, `oc`, and `kubectl`) binaries from `https://mirror.openshift.com/pub/openshift-v4/clients/ocp/4.22.16/` into `~/bin/`.
3. Activates `${PREFIX}-sa-key.json` and loads `${PREFIX}-ssh` into `ssh-agent`.
4. Copies `install-config.yaml` into `~/ocp-cluster/` (preserving `~/ocp-setup/install-config.yaml.bak`).
5. Prompts you for confirmation and executes:
   ```bash
   openshift-install create cluster --dir=$HOME/ocp-cluster --log-level=info
   ```
6. Copies `~/ocp-cluster/auth/kubeconfig` to `~/.kube/config` so `oc` works immediately upon completion.

### 5.3 Troubleshooting: If Installation Fails (Restart or Delete Cluster)
If `openshift-install create cluster` fails, the script automatically prints recovery commands. You can run any of the following on the Bastion VM:

- **Option A — Resume / Wait for Install Completion (if a step timed out)**:
  ```bash
  export GOOGLE_APPLICATION_CREDENTIALS="$HOME/ocp-setup/${PREFIX}-sa-key.json"
  openshift-install wait-for bootstrap-complete --dir="$HOME/ocp-cluster" --log-level=info
  openshift-install wait-for install-complete --dir="$HOME/ocp-cluster" --log-level=info
  ```

- **Option B — Destroy Failed Cluster & Restart Fresh Installation**:
  ```bash
  ~/ocp-setup/05-bastion-install-ocp.sh restart
  ```
  *(Or manually)*:
  ```bash
  export GOOGLE_APPLICATION_CREDENTIALS="$HOME/ocp-setup/${PREFIX}-sa-key.json"
  openshift-install destroy cluster --dir="$HOME/ocp-cluster" --log-level=info
  rm -rf "$HOME/ocp-cluster" && mkdir -p "$HOME/ocp-cluster"
  cp "$HOME/ocp-setup/install-config.yaml.bak" "$HOME/ocp-cluster/install-config.yaml"
  openshift-install create cluster --dir="$HOME/ocp-cluster" --log-level=info
  ```

- **Option C — Delete / Destroy Cluster Only**:
  ```bash
  ~/ocp-setup/05-bastion-install-ocp.sh destroy
  ```
  *(Or manually)*:
  ```bash
  export GOOGLE_APPLICATION_CREDENTIALS="$HOME/ocp-setup/${PREFIX}-sa-key.json"
  openshift-install destroy cluster --dir="$HOME/ocp-cluster" --log-level=info
  rm -rf "$HOME/ocp-cluster"
  ```

---

## Step 6: Test Cluster Connections (`06-access-and-test.sh` — Runs on Local Workstation)

> [!IMPORTANT]
> **Execution Location: LOCAL WORKSTATION ONLY**
> `06-access-and-test.sh` runs on your **Local Workstation** (not inside the Bastion VM). Exit your Bastion SSH session (or open a new terminal tab on your local workstation) before running `./scripts/06-access-and-test.sh`.

After the installation finishes (~35–45 minutes), verify DNS, API server health, Ingress health, and node readiness:

### Option A: Run Automated Connection Test (From Local Workstation)
```bash
./scripts/06-access-and-test.sh test
```

### Option B: Run `oc` Commands Directly (Inside Bastion VM)
```bash
export KUBECONFIG=~/.kube/config
oc whoami
oc get nodes -o wide
oc get clusterversion
oc get co
```

---

## Step 7: HTTPS Tunnel to Local Machine for Web Console Access (`06-access-and-test.sh` — Runs on Local Workstation)

> [!IMPORTANT]
> **Execution Location: LOCAL WORKSTATION ONLY**
> Both `./scripts/06-access-and-test.sh hosts` and `./scripts/06-access-and-test.sh tunnel` must be run on your **Local Workstation** where your web browser is running.

Because the cluster uses `publish: Internal` with a private domain (`${PREFIX}.openshiftapps.local`), use an IAP SSH port-forwarding tunnel to access the OpenShift Web Console from your local browser.

> [!NOTE]
> **Single Tunnel & Loopback IP (`127.0.0.2`) for Web Console & Apps**: Because `127.0.0.1` may already be used by other local services, this setup binds **`127.0.0.2`** (`CONSOLE_LOCAL_IP`). Since OpenShift's HAProxy Ingress Router routes traffic by TLS SNI (`:443`) and HTTP `Host` header (`:80`), this **single `127.0.0.2` tunnel** serves both the OpenShift Web Console and any Phase 2 application routes added to `/etc/hosts`.

### 7.1 Add Console & OAuth Hostnames (`127.0.0.2`) to Local `/etc/hosts`
On your **local machine**, run:

```bash
./scripts/06-access-and-test.sh hosts
```

*(Or manually)*:
```bash
source config.env
sudo sh -c "cat <<EOF >> /etc/hosts
127.0.0.2 console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}
127.0.0.2 oauth-openshift.apps.${CLUSTER_NAME}.${BASE_DOMAIN}
EOF"
```

### 7.2 Start the HTTPS/HTTP Port-Forwarding Tunnel (`127.0.0.2:443` & `:80`)
On your **local machine**, run:

```bash
./scripts/06-access-and-test.sh tunnel
```

*(Or manually)*:
```bash
source config.env
sudo gcloud auth login
sudo gcloud compute ssh "${BASTION_NAME}" \
  --project="${PROJECT_ID}" \
  --zone="${ZONE}" \
  --tunnel-through-iap \
  -- -N \
  -L "127.0.0.2:443:console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}:443" \
  -L "127.0.0.2:80:console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}:80"
```

### 7.3 Open the Web Console in Your Browser
1. Open `https://console-openshift-console.apps.<PREFIX>-cluster.<PREFIX>.openshiftapps.local` in your local browser.
2. Log in with username `kubeadmin` and the password displayed by `./scripts/06-access-and-test.sh test` (stored in `~/ocp-cluster/auth/kubeadmin-password` on the Bastion VM).

> [!TIP]
> **Running on Windows WSL (WSL 2)?**
> 1. **Clone in `~/` (Not `/mnt/c/`)**: Ensure the repository is cloned inside your native WSL Linux filesystem (e.g., `~/ocp-gcp-demo`) so `chmod 600` works properly on SSH keys.
> 2. **Loopback IP (`127.0.0.1`)**: `00-prereq-config.sh` automatically detects WSL and sets `CONSOLE_LOCAL_IP="127.0.0.1"` in `config.env` so Windows `localhost` forwarding reaches the tunnel inside WSL 2.
> 3. **Windows `hosts` File**: When using a browser on Windows (Chrome/Edge), run the **Administrator PowerShell** command printed by `./scripts/06-access-and-test.sh hosts` to append the OpenShift Console, OAuth, and Phase 2 Cymbal routes to `C:\Windows\System32\drivers\etc\hosts`:
>    ```powershell
>    # Run in Windows PowerShell as Administrator:
>    Add-Content -Path C:\Windows\System32\drivers\etc\hosts -Value "`r`n127.0.0.1 console-openshift-console.apps.<CLUSTER_NAME>.<BASE_DOMAIN>`r`n127.0.0.1 oauth-openshift.apps.<CLUSTER_NAME>.<BASE_DOMAIN>`r`n127.0.0.1 cymbal-storefront-cymbal-storefront.apps.<CLUSTER_NAME>.<BASE_DOMAIN>`r`n127.0.0.1 cymbal-ledger-cymbal-stateful.apps.<CLUSTER_NAME>.<BASE_DOMAIN>"
>    ```

---

## Step 8: Stopping & Starting Cluster VMs to Save Costs (`08-stop-start-vms.sh`)

When you are not actively using the demo environment, you can gracefully stop all OpenShift cluster nodes and the Bastion VM without destroying the cluster:

```bash
# 1. Check current RUNNING / TERMINATED status of all Cluster & Bastion VMs:
./scripts/08-stop-start-vms.sh status

# 2. Gracefully stop Workers -> Control Plane Masters -> Bastion VM:
./scripts/08-stop-start-vms.sh stop

#    (Optional) Stop only the OpenShift cluster VMs while keeping the Bastion VM running:
./scripts/08-stop-start-vms.sh stop --keep-bastion

# 3. Start Bastion -> Control Plane Masters -> Workers & auto-approve pending node CSRs:
./scripts/08-stop-start-vms.sh start
```

---

## Step 9: How to Remove the Cluster & Infrastructure (Cleanup)

Always remove the OpenShift cluster **first** using `openshift-install destroy cluster` before deleting the VPC or Service Account so the installer can cleanly remove all cluster-created VMs, disks, load balancers, firewall rules, Cloud DNS private zones, and GCS buckets.

### Option A: Automated Full Teardown (`07-cleanup.sh`)
From your **local workstation**, run:

```bash
./scripts/07-cleanup.sh
```
This script automatically connects to the Bastion VM to destroy the OpenShift cluster, and then deletes the Bastion VM, Firewall rules, Cloud NAT, Cloud Router, the 3 Subnets, the VPC, the Service Account, and local `/etc/hosts` entries in the proper dependency order.

### Option B: Step-by-Step Manual Removal Commands

#### 1. Destroy the OpenShift Cluster (Run on Bastion VM)
```bash
~/ocp-setup/05-bastion-install-ocp.sh destroy
```
*(Or manually on the Bastion VM)*:
```bash
export GOOGLE_APPLICATION_CREDENTIALS="$HOME/ocp-setup/${PREFIX}-sa-key.json"
openshift-install destroy cluster --dir="$HOME/ocp-cluster" --log-level=info
rm -rf "$HOME/ocp-cluster"
```

#### 2. Delete the Bastion VM, Network & IAM Resources (Run on Local Machine)
```bash
source config.env

# 1. Delete Bastion VM
gcloud compute instances delete "${BASTION_NAME}" \
  --zone="${ZONE}" --project="${PROJECT_ID}" --quiet

# 2. Delete Firewall Rules
gcloud compute firewall-rules delete "${FW_IAP_SSH}" "${FW_INTERNAL}" \
  --project="${PROJECT_ID}" --quiet

# 3. Delete Cloud NAT and Cloud Router
gcloud compute routers nats delete "${NAT_NAME}" \
  --router="${ROUTER_NAME}" --region="${REGION}" --project="${PROJECT_ID}" --quiet
gcloud compute routers delete "${ROUTER_NAME}" \
  --region="${REGION}" --project="${PROJECT_ID}" --quiet

# 4. Delete the 3 Subnets and Custom VPC
gcloud compute networks subnets delete \
  "${SUBNET_BASTION}" "${SUBNET_WORKER}" "${SUBNET_CONTROL_PLANE}" \
  --region="${REGION}" --project="${PROJECT_ID}" --quiet
gcloud compute networks delete "${VPC_NAME}" \
  --project="${PROJECT_ID}" --quiet

# 5. Delete the OCP Service Account
gcloud iam service-accounts delete "${SA_EMAIL}" \
  --project="${PROJECT_ID}" --quiet

# 6. Remove local generated keys and /etc/hosts entries
sudo sed -i.bak "/.${CLUSTER_NAME}.${BASE_DOMAIN}/d" /etc/hosts
rm -rf generated/ config.env
```

---

## Known & Solved Issues

### 1. Solved Issue: `MachineWithoutValidNode` Warning (`bad shim signature` During 4.13 Marketplace $\rightarrow$ 4.22 Pivot Reboot)
- **Symptom**: A worker `Machine` remains in `Provisioned` phase (`MachineWithoutValidNode: machine <name> does not have valid node reference`) while its GCP VM is `RUNNING`. Checking `gcloud compute instances get-serial-port-output <VM_NAME>` shows:
  ```text
  Booting `Red Hat Enterprise Linux CoreOS 9.8.20260922-1 (Plow) (ostree:0)'
  error: ../../grub-core/kern/efi/sb.c:182:bad shim signature.
  error: ../../grub-core/loader/i386/efi/linux.c:258:you need to load the kernel first.
  ```
- **Root Cause & Why Only One Node May Be Affected**:
  - When `USE_MARKETPLACE_IMAGE="true"` is enabled, nodes first boot from the RHCOS 4.13 Marketplace image (`redhat-coreos-ocp-413-x86-64-202305021736`, which contains the 2023 UEFI `shimx64.efi`), download the OCP 4.22 (RHCOS 9.8) OS image, run `bootupd` (`bootupctl`) to update `/boot/efi/EFI/redhat/shimx64.efi`, and reboot into `ostree:0` (RHCOS 9.8).
  - On most nodes, `bootupd` finishes flushing the new 4.22 `shimx64.efi` to `/boot/efi` before the reboot. However, if the pivot reboot occurs before `/boot/efi` is flushed on a given node, the 2023 shim remains on the EFI partition and rejects the 2026 RHCOS 9.8 kernel signature when GCP Shielded VM Secure Boot (`secureBoot: Enabled`) is active.
- **Permanent Fix (Built into `04-bastion-setup.sh`)**:
  - `04-bastion-setup.sh` automatically sets `secureBoot: Disabled` in `install-config.yaml` whenever `USE_MARKETPLACE_IMAGE="true"`.
- **Live Recovery for an Affected Node**:
  ```bash
  # 1. Stop the affected VM, disable Shielded VM Secure Boot, and start it back up:
  gcloud compute instances stop <VM_NAME> --zone=<ZONE> --project=<PROJECT_ID>
  gcloud compute instances update <VM_NAME> --zone=<ZONE> --project=<PROJECT_ID> --no-shielded-secure-boot
  gcloud compute instances start <VM_NAME> --zone=<ZONE> --project=<PROJECT_ID>

  # 2. On the Bastion VM, approve the node's pending CSRs so it joins the cluster:
  for csr in $(oc get csr --no-headers | awk '/Pending/ {print $1}'); do
    oc adm certificate approve "$csr"
  done
  ```

### 2. Missing Worker Nodes When Using `n4-custom-*` VMs
- **Symptom**: During or after installation, you see only `worker-a` and `worker-b` nodes (or fewer than 3 worker nodes) in `oc get nodes` / `oc get machines -n openshift-machine-api`.
- **Cause**: In a multi-zone deployment, OpenShift creates worker `MachineSet`s across the region's availability zones (`-a`, `-b`, `-c`). Newer machine series like **N4 (`n4-custom-6-20480`)** may only be available in a subset of zones in certain regions (e.g., zones `a` and `b`, but not `c`).
- **Resolution**:
  1. Check the `MachineSet` status on the Bastion VM:
     ```bash
     oc get machineset -n openshift-machine-api
     oc get machine -n openshift-machine-api
     ```
  2. Scale up the `MachineSet` in an available zone (such as zone `a` or `b`) to reach your desired worker count:
     ```bash
     oc scale machineset <worker-a-machineset-name> -n openshift-machine-api --replicas=2
     ```

---

## More Information & Official Documentation

- [**Phase 2 (Optional): Google Cloud Cymbal Demo Workloads (`workloads/README.md`)**](../workloads/README.md)
- [**Phase 3 (Optional): Google Cloud Workload Manager & OpenShift Telemetry Operator (`workload-manager/README.md`)**](../workload-manager/README.md)
- [Red Hat OpenShift Container Platform 4.22: Installing on Google Cloud](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/installing_on_google_cloud/index)
- [Red Hat OpenShift Container Platform Life Cycle Policy](https://access.redhat.com/product-life-cycles?product=Red%20Hat%20OpenShift%20Container%20Platform)
- [Google Cloud: Red Hat OpenShift on Google Cloud Overview](https://docs.cloud.google.com/openshift-cluster/openshift-overview)
- [Google Cloud Workload Manager: Set up Cluster Services for OpenShift Telemetry Operator](https://docs.cloud.google.com/workload-manager/docs/evaluate/set-up-operator-for-openshift)
- [Google Cloud & Red Hat Solutions](https://cloud.google.com/solutions/redhat)
- [Google Cloud Blog: Red Hat OpenShift on Google Cloud Migration and Scaling Updates](https://cloud.google.com/blog/topics/partners/red-hat-openshift-on-google-cloud-migration-and-scaling-updates)
- [Red Hat OpenShift Pull Secret Download](https://console.redhat.com/openshift/install/pull-secret)
