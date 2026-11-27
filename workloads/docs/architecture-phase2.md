# Phase 2 Architecture: Cymbal Workloads on OpenShift & Google Cloud

This document describes the architecture for the two independent Phase 2 workload options running on the private Red Hat OpenShift Container Platform (OCP 4.22) cluster on Google Cloud.

---

## Option 1 Architecture: Stateless Cymbal Storefront with Regional Private Cloud Filestore

Option 1 demonstrates how a **stateless, multi-replica web tier** (`Cymbal Retail Storefront`) scales horizontally across multiple availability zones while reading and writing shared assets and real-time access logs on a **regional, private Google Cloud Filestore (`Enterprise` tier)** volume provisioned dynamically via the **GCP Filestore CSI Driver Operator**.

```mermaid
%%{init: {'theme': 'base', 'themeVariables': { 'background': '#ffffff', 'primaryTextColor': '#1f2937', 'lineColor': '#475569' }}}%%
flowchart TB
    subgraph Local["Local Workstation"]
        Browser["Browser\nhttps://cymbal-storefront-cymbal-storefront.apps.<CLUSTER>.<DOMAIN>"]:::browser
    end

    subgraph VPC["Custom VPC: <PREFIX>-vpc"]
        Bastion["Bastion VM (<PREFIX>-vm-bastion)\nIAP SSH Tunnel (127.0.0.2:443)"]:::bastion

        subgraph OCP["OpenShift 4.22 Cluster (Worker Subnet)"]
            Ingress["OpenShift Internal Router (*.apps :443)\nRoute: cymbal-storefront (TLS Edge)"]:::lb
            Svc["Service: cymbal-storefront-svc (:8080)"]:::service

            subgraph NS1["Namespace: cymbal-storefront"]
                Pod1["Cymbal Storefront Pod 1 (Zone a)\nStateless UBI9 Httpd"]:::pod
                Pod2["Cymbal Storefront Pod 2 (Zone b)\nStateless UBI9 Httpd"]:::pod
                Pod3["Cymbal Storefront Pod 3 (Zone c)\nStateless UBI9 Httpd"]:::pod
                PVC1["PVC: cymbal-shared-assets-pvc\nAccessMode: ReadWriteMany (1Ti)"]:::pvc
            end

            FilestoreCSI["GCP Filestore CSI Driver Operator\n(filestore.csi.storage.gke.io)\nStorageClass: filestore-regional-csi"]:::operator
        end

        PSA["Private Service Access (PSA)\nVPC Peering (servicenetworking.googleapis.com)\nAllocated /20 Range: <PREFIX>-psa-range"]:::network
    end

    subgraph ManagedNet["Google Managed Services Network"]
        Filestore["Regional Cloud Filestore (Enterprise Tier)\nMulti-Zone High Availability NFSv3 Share\nPrivate IP Only"]:::storage
    end

    Browser -->|"127.0.0.2:443"| Bastion
    Bastion --> Ingress
    Ingress --> Svc
    Svc --> Pod1 & Pod2 & Pod3
    Pod1 & Pod2 & Pod3 -->|"ReadWriteMany (/mnt/cymbal-filestore)"| PVC1
    PVC1 -.->|"Dynamic Provisioning"| FilestoreCSI
    FilestoreCSI -.->|"Creates Regional Instance"| Filestore
    Pod1 & Pod2 & Pod3 <-->|"NFSv3 over Private Service Access"| PSA
    PSA <--> Filestore

    classDef browser fill:#e0f2fe,stroke:#0284c7,stroke-width:2px,color:#0c4a6e
    classDef bastion fill:#fef3c7,stroke:#d97706,stroke-width:2px,color:#78350f
    classDef lb fill:#dbeafe,stroke:#2563eb,stroke-width:2px,color:#1e3a8a
    classDef service fill:#ccfbf1,stroke:#0d9488,stroke-width:2px,color:#134e4a
    classDef pod fill:#dcfce7,stroke:#16a34a,stroke-width:2px,color:#14532d
    classDef pvc fill:#fef9c3,stroke:#ca8a04,stroke-width:2px,color:#713f12
    classDef operator fill:#e0e7ff,stroke:#4f46e5,stroke-width:2px,color:#312e81
    classDef network fill:#f3e8ff,stroke:#9333ea,stroke-width:2px,color:#3b0764
    classDef storage fill:#ffedd5,stroke:#ea580c,stroke-width:2px,color:#7c2d12

    style Local fill:#f8fafc,stroke:#94a3b8,stroke-width:1.5px,color:#0f172a
    style VPC fill:#f0f9ff,stroke:#0284c7,stroke-width:2px,stroke-dasharray: 5 5,color:#0369a1
    style OCP fill:#fff1f2,stroke:#fb7185,stroke-width:1.5px,color:#9f1239
    style NS1 fill:#f0fdf4,stroke:#4ade80,stroke-width:1.5px,color:#166534
    style ManagedNet fill:#fff7ed,stroke:#fb923c,stroke-width:1.5px,color:#9a3412
```

### Key Architectural Components (Option 1)
1. **Private Service Access (PSA) & VPC Peering**:
   - Because the OpenShift cluster is strictly private and uses custom subnets, regional Cloud Filestore (`Enterprise` tier) connects to `${PREFIX}-vpc` via **Private Service Access** (`servicenetworking.googleapis.com`) using a dedicated `/20` peering IP range (`${PREFIX}-psa-range`).
2. **GCP Filestore CSI Driver Operator**:
   - Installed in `openshift-cluster-csi-drivers` via Operator Lifecycle Manager (OLM) and managed through `ClusterCSIDriver` (`filestore.csi.storage.gke.io`).
   - Provides dynamic provisioning of regional `ReadWriteMany` (`RWX`) NFS volumes via `StorageClass` `filestore-regional-csi` (`tier: enterprise`, `connect-mode: PRIVATE_SERVICE_ACCESS`).
3. **Cymbal Retail Storefront (Stateless Multi-Replica Deployment)**:
   - Runs 3 stateless web replicas spread across worker nodes.
   - All 3 pods concurrently mount `/mnt/cymbal-filestore` (`ReadWriteMany`), sharing product catalog assets and appending real-time pod/node request telemetry so users can observe multi-pod `RWX` storage sharing in real time.

---

## Option 2 Architecture: Stateful Cymbal Ledger with Hyperdisk Block Storage & Secret Manager

Option 2 demonstrates how a **stateful database and transaction ledger** (`Cymbal Order & Inventory Ledger`) persists transactional data on **Google Cloud Hyperdisk Balanced** block storage (`ReadWriteOnce`) while mounting database credentials and API keys directly from **Google Cloud Secret Manager** using the **Secrets Store CSI Driver Operator**.

```mermaid
%%{init: {'theme': 'base', 'themeVariables': { 'background': '#ffffff', 'primaryTextColor': '#1f2937', 'lineColor': '#475569' }}}%%
flowchart TB
    subgraph Local["Local Workstation"]
        Browser2["Browser\nhttps://cymbal-ledger-cymbal-stateful.apps.<CLUSTER>.<DOMAIN>"]:::browser
    end

    subgraph GCP_Sec["Google Cloud Security & Block Storage"]
        GSM["Google Cloud Secret Manager\n- <PREFIX>-cymbal-db-password\n- <PREFIX>-cymbal-api-key"]:::security
        Hyperdisk["Google Cloud Hyperdisk Balanced\n20Gi Block Volume (ReadWriteOnce)\nProvisioned via pd.csi.storage.gke.io"]:::storage
    end

    subgraph VPC["Custom VPC: <PREFIX>-vpc"]
        Bastion2["Bastion VM (<PREFIX>-vm-bastion)\nIAP SSH Tunnel (127.0.0.2:443)"]:::bastion

        subgraph OCP2["OpenShift 4.22 Cluster (Worker Subnet)"]
            Ingress2["OpenShift Internal Router (*.apps :443)\nRoute: cymbal-ledger (TLS Edge)"]:::lb

            subgraph NS2["Namespace: cymbal-stateful"]
                UI["Cymbal Ledger Web UI Pod\nQueries PostgreSQL & Displays Live Ledger"]:::pod
                DB["StatefulSet: cymbal-ledger-db-0\nPostgreSQL 16"]:::database
                SPC["SecretProviderClass: cymbal-gcp-secrets\nMounts /mnt/secrets-store (tmpfs only)"]:::secretcr
                RWO_PVC["VolumeClaimTemplate PVC\ncymbal-hyperdisk-data (20Gi)\nStorageClass: hyperdisk-balanced-csi"]:::pvc
            end

            SecretsCSI["Secrets Store CSI Driver Operator\n(secrets-store.csi.k8s.io)\n+ GCP Provider DaemonSet"]:::operator
            PD_CSI["GCP PD CSI Driver\n(pd.csi.storage.gke.io)"]:::csi
        end
    end

    Browser2 -->|"127.0.0.2:443"| Bastion2
    Bastion2 --> Ingress2
    Ingress2 --> UI
    UI -->|"SQL (:5432)"| DB
    DB -->|"Block I/O (/var/lib/pgsql/data)"| RWO_PVC
    RWO_PVC --> PD_CSI
    PD_CSI --> Hyperdisk
    DB & UI -->|"CSI Inline Volume (/mnt/secrets-store)"| SPC
    SPC --> SecretsCSI
    SecretsCSI -->|"Fetches Secrets via IAM"| GSM

    classDef browser fill:#e0f2fe,stroke:#0284c7,stroke-width:2px,color:#0c4a6e
    classDef security fill:#f3e8ff,stroke:#9333ea,stroke-width:2px,color:#3b0764
    classDef storage fill:#ffedd5,stroke:#ea580c,stroke-width:2px,color:#7c2d12
    classDef bastion fill:#fef3c7,stroke:#d97706,stroke-width:2px,color:#78350f
    classDef lb fill:#dbeafe,stroke:#2563eb,stroke-width:2px,color:#1e3a8a
    classDef pod fill:#dcfce7,stroke:#16a34a,stroke-width:2px,color:#14532d
    classDef database fill:#fce7f3,stroke:#db2777,stroke-width:2px,color:#831843
    classDef secretcr fill:#fae8ff,stroke:#c026d3,stroke-width:2px,color:#701a75
    classDef pvc fill:#fef9c3,stroke:#ca8a04,stroke-width:2px,color:#713f12
    classDef operator fill:#e0e7ff,stroke:#4f46e5,stroke-width:2px,color:#312e81
    classDef csi fill:#ccfbf1,stroke:#0d9488,stroke-width:2px,color:#134e4a

    style Local fill:#f8fafc,stroke:#94a3b8,stroke-width:1.5px,color:#0f172a
    style GCP_Sec fill:#faf5ff,stroke:#a855f7,stroke-width:1.5px,color:#581c87
    style VPC fill:#f0f9ff,stroke:#0284c7,stroke-width:2px,stroke-dasharray: 5 5,color:#0369a1
    style OCP2 fill:#fff1f2,stroke:#fb7185,stroke-width:1.5px,color:#9f1239
    style NS2 fill:#f0fdf4,stroke:#4ade80,stroke-width:1.5px,color:#166534
```

### Key Architectural Components (Option 2)
1. **Google Cloud Hyperdisk Balanced (`hyperdisk-balanced-csi`)**:
   - Uses the built-in OpenShift `pd.csi.storage.gke.io` CSI driver with `type: hyperdisk-balanced` and `volumeBindingMode: WaitForFirstConsumer`, matching the N4 worker nodes' next-generation Hyperdisk storage architecture.
2. **Secrets Store CSI Driver Operator + GCP Provider**:
   - Installs the OpenShift **Secrets Store CSI Driver Operator** (`secrets-store.csi.k8s.io`) and the **Google Cloud Provider DaemonSet** (`csi-secrets-store-provider-gcp`) in `openshift-cluster-csi-drivers`.
   - Uses a `SecretProviderClass` (`cymbal-gcp-secrets`) to fetch secrets directly from **Google Cloud Secret Manager** (`${PREFIX}-cymbal-db-password` and `${PREFIX}-cymbal-api-key`), mounting them as in-memory tmpfs files at `/mnt/secrets-store` and syncing them to an OpenShift `Secret` for database initialization.
3. **Cymbal Order & Inventory Ledger (`StatefulSet` + Web Dashboard)**:
   - **`cymbal-ledger-db` (`StatefulSet`)**: Runs PostgreSQL 16 backed by a dedicated 20 GiB `hyperdisk-balanced` persistent volume (`cymbal-hyperdisk-data-cymbal-ledger-db-0`).
   - **`cymbal-ledger-ui`**: Seeds and queries Cymbal retail inventory and order ledger records stored in PostgreSQL on Hyperdisk, displaying live database records, Hyperdisk volume metadata, and Secret Manager CSI mount verification.
