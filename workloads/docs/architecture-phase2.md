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
   - Uses a `SecretProviderClass` (`cymbal-gcp-secrets`) to fetch secrets directly from **Google Cloud Secret Manager** (`${PREFIX}-cymbal-db-password` and `${PREFIX}-cymbal-api-key`), mounting them exclusively as in-memory `tmpfs` files at `/mnt/secrets-store` (no `etcd` `Secret` sync).
3. **Cymbal Order & Inventory Ledger (`StatefulSet` + Web Dashboard)**:
   - **`cymbal-ledger-db` (`StatefulSet`)**: Runs PostgreSQL 16 backed by a dedicated 20 GiB `hyperdisk-balanced` persistent volume (`cymbal-hyperdisk-data-cymbal-ledger-db-0`).
   - **`cymbal-ledger-ui`**: Seeds and queries Cymbal retail inventory and order ledger records stored in PostgreSQL on Hyperdisk, displaying live database records, Hyperdisk volume metadata, and Secret Manager CSI mount verification.

---

## Option 3 Architecture: Public Edge Storefront with Cloud Armor WAF, DDoS, Cloud CDN & Global External ALB

Option 3 demonstrates how to expose a **public-facing enterprise workload** (`Cymbal Global Public Storefront`) from a **100% Private Red Hat OpenShift (`publish: Internal`)** cluster using Google Cloud's defense-in-depth edge security and observability stack—while keeping the OpenShift API (`:6443`), Web Console, OAuth server, and worker nodes completely private (zero public IP addresses on cluster nodes):

```mermaid
%%{init: {'theme': 'base', 'themeVariables': { 'background': '#ffffff', 'primaryTextColor': '#1e293b', 'lineColor': '#475569'}}}%%
flowchart TB
    subgraph Internet["Public Internet & Global Probers"]
        Users["Legitimate Public Users\nhttps://cymbal.<PUBLIC_VIP>.nip.io"]:::client
        Attackers["Malicious Traffic\n(SQLi, XSS, LFI, RCE, Scanners, L7 DDoS)"]:::redhat
        Uptime["Cloud Monitoring Global Uptime Check\nProbes /healthz from US, EU & APAC"]:::dns
    end

    subgraph GoogleEdge["Google Cloud Global Edge (180+ Anycast POPs)"]
        VIP["Global Static Anycast IPv4 (<PREFIX>-public-waf-vip)\nAlways-On Google L3/L4 Volumetric DDoS Protection"]:::lb
        HTTPS_Proxy["Global External Application Load Balancer (EXTERNAL_MANAGED)\n• Target HTTPS Proxy (:443) + SSL Policy (TLS 1.2/1.3 MODERN)\n• Custom Security Headers (HSTS, X-Frame-Options, X-CDN-Cache-Status)"]:::lb
        CloudArmor["Google Cloud Armor WAF & DDoS Policy (<PREFIX>-cloud-armor-waf)\n• Priority 1000–1008: OWASP CRS 4.22 (SQLi, XSS, LFI, RCE, RFI, Generic -> 403)\n• Priority 2000: Rate-Based Ban / L7 DDoS (100 req/min/IP -> 429)"]:::iam
        CloudCDN["Google Cloud CDN (Global Edge Cache)\nCaches /static/* & Catalog Assets at Edge POPs (HIT / MISS)"]:::storage
        BackendSvc["Global Backend Service (<PREFIX>-public-backend-svc)\n+ HTTP Health Check (/healthz)"]:::lb
    end

    subgraph CloudOps["Google Cloud Operations (Observability & Audit)"]
        CloudLog["Cloud Logging\n• 100% ALB & Cloud Armor WAF Audit Logs\n• Firewall Rule & VPC Flow Logs"]:::secret
    end

    subgraph VPC["Private Custom VPC: <PREFIX>-vpc (Zero Public IPs on Nodes)"]
        FW_GFE["Least-Privilege GFE Firewall Rule (<PREFIX>-allow-gfe-public-neg)\n• Source ONLY GFEs: 130.211.0.0/22, 35.191.0.0/16\n• Target Tag: <infra-id>-worker | Port ONLY: tcp:30080\n• Firewall Rule Logging: ENABLED"]:::network

        subgraph SubWorker["Worker Subnet: <PREFIX>-subnet-worker (/23 — VPC Flow Logs ENABLED)"]
            NEG_A["Zonal NEG (Zone a)\nGCE_VM_IP_PORT :30080"]:::infra
            NEG_B["Zonal NEG (Zone b)\nGCE_VM_IP_PORT :30080"]:::infra
            NEG_C["Zonal NEG (Zone c)\nGCE_VM_IP_PORT :30080"]:::infra

            subgraph PublicNS["OpenShift Namespace: cymbal-public"]
                NP_Svc["NodePort Service (:30080 -> :8080)\ncymbal-public-neg-svc"]:::network
                PodA["Cymbal Public Edge Pod 1 (Zone a)\nNon-Root SCC (restricted-v2)"]:::worker
                PodB["Cymbal Public Edge Pod 2 (Zone b)\nNon-Root SCC (restricted-v2)"]:::worker
                PodC["Cymbal Public Edge Pod 3 (Zone c)\nNon-Root SCC (restricted-v2)"]:::worker
                NetPol["Kubernetes NetworkPolicy\nIsolates Namespace Traffic"]:::iam
            end
        end

        subgraph PrivateControl["Strictly Private Control Plane & Console (100% Isolated)"]
            PrivAPI["Private API (:6443) & Console (:443)\nUnreachable from Public ALB"]:::bastion
        end
    end

    Users -->|"HTTPS :443"| VIP
    Uptime -.->|"Synthetic HTTPS Probe"| VIP
    Attackers -.-x|"Blocked at Edge (403 / 429)"| CloudArmor
    VIP --> HTTPS_Proxy
    HTTPS_Proxy --> CloudArmor
    CloudArmor -->|"Allowed Traffic"| CloudCDN
    CloudCDN -->|"Cache Miss / Dynamic"| BackendSvc
    BackendSvc -->|"Google Internal SDN"| FW_GFE
    FW_GFE --> NEG_A & NEG_B & NEG_C
    NEG_A & NEG_B & NEG_C --> NP_Svc
    NP_Svc --> PodA & PodB & PodC
    CloudArmor & BackendSvc & FW_GFE -.->|"Real-Time Telemetry"| CloudLog

    classDef client fill:#e0f2fe,stroke:#0284c7,stroke-width:2px,color:#0c4a6e
    classDef redhat fill:#ffe4e6,stroke:#e11d48,stroke-width:2px,color:#881337
    classDef dns fill:#ccfbf1,stroke:#0d9488,stroke-width:2px,color:#134e4a
    classDef iam fill:#fef3c7,stroke:#d97706,stroke-width:2px,color:#78350f
    classDef storage fill:#ecfccb,stroke:#65a30d,stroke-width:2px,color:#365314
    classDef secret fill:#fce7f3,stroke:#db2777,stroke-width:2px,color:#831843
    classDef network fill:#e0e7ff,stroke:#4f46e5,stroke-width:2px,color:#312e81
    classDef lb fill:#f3e8ff,stroke:#9333ea,stroke-width:2px,color:#581c87
    classDef bastion fill:#dbeafe,stroke:#2563eb,stroke-width:2px,color:#1e3a8a
    classDef infra fill:#cffafe,stroke:#0891b2,stroke-width:2px,color:#164e63
    classDef worker fill:#dcfce7,stroke:#16a34a,stroke-width:2px,color:#14532d

    style Internet fill:#f8fafc,stroke:#94a3b8,stroke-width:1.5px,color:#0f172a
    style GoogleEdge fill:#faf5ff,stroke:#9333ea,stroke-width:2px,color:#581c87
    style CloudOps fill:#fdf2f8,stroke:#ec4899,stroke-width:1.5px,color:#831843
    style VPC fill:#ffffff,stroke:#475569,stroke-width:2px,stroke-dasharray: 5 5,color:#0f172a
    style SubWorker fill:#f0fdf4,stroke:#22c55e,stroke-width:1.5px,color:#14532d
    style PublicNS fill:#dcfce7,stroke:#4ade80,stroke-width:1.5px,color:#14532d
    style PrivateControl fill:#eff6ff,stroke:#3b82f6,stroke-width:1.5px,color:#1e3a8a
```

### Key Architectural Components (Option 3)
1. **Google Cloud Armor WAF & L7 DDoS (`${PREFIX}-cloud-armor-waf`)**:
   - Blocks OWASP Top 10 attacks (`sqli-v422-stable`, `xss-v422-stable`, `lfi-v422-stable`, `rce-v422-stable`, `scannerdetection-v422-stable`, `protocolattack-v422-stable`, `rfi-v422-stable`, `sessionfixation-v422-stable`, `generic-v422-stable`) at Google's Global Edge (`403 Forbidden`) and enforces per-IP L7 rate limiting (`100 req/min` $\rightarrow$ `429 Too Many Requests` ban for `120s`).
2. **Global External Application Load Balancer (`EXTERNAL_MANAGED`) + Cloud CDN + SSL Policy**:
   - Terminates HTTPS (`:443`) using a `MODERN` TLS 1.2+ SSL Policy, caches `/static/catalog.json` at 180+ Google Edge POPs via **Cloud CDN**, and injects security response headers (`Strict-Transport-Security`, `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`).
3. **Zonal `GCE_VM_IP_PORT` NEGs + Least-Privilege GFE Firewall Rule**:
   - Routes clean traffic over Google's internal SDN directly to private OCP worker VMs across Zones `-a`, `-b`, `-c` on NodePort `:30080`, restricted by `${PREFIX}-allow-gfe-public-neg` (`130.211.0.0/22`, `35.191.0.0/16` only) with Firewall Rule Logging and sampled VPC Flow Logs enabled.
4. **Cloud Logging & Cloud Monitoring Global Uptime Check**:
   - Streams 100% of ALB and Cloud Armor security events into Cloud Logging and continuously probes `/healthz` from USA, Europe, and Asia-Pacific via Cloud Monitoring.
