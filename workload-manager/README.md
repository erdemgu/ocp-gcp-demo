# Phase 3 (Optional): Google Cloud Workload Manager & Cluster Services for OpenShift Telemetry Operator (Preview)

Phase 3 is **optional** and installs the **Cluster Services for OpenShift Telemetry Operator** (`google-cloud-cluster-services-for-openshift-telemetry`, Preview) on your private Red Hat OpenShift Container Platform (OCP 4.22) cluster.

Once installed and configured via a `TelemetryConfig` custom resource, the operator continuously collects OpenShift cluster health, node configuration, storage, and security telemetry (every 30 minutes or on-demand) and sends insights to **Google Cloud Workload Manager** so you can evaluate your cluster against Google Cloud and Red Hat best practices.

> [!IMPORTANT]
> **Preview Feature Notice**: Google Cloud Workload Manager support for Red Hat OpenShift and the **Cluster Services for OpenShift Telemetry Operator** (`google-cloud-cluster-services-for-openshift-telemetry`) are currently in **Preview** (Pre-GA). Features, custom resource specifications (`TelemetryConfig`), and evaluation rules may change before General Availability.
> - **Official Google Cloud Documentation**: [Set up Cluster Services for OpenShift Telemetry Operator](https://docs.cloud.google.com/workload-manager/docs/evaluate/set-up-operator-for-openshift)

---

## Architecture Overview

```mermaid
%%{init: {'theme': 'base', 'themeVariables': { 'background': '#ffffff', 'primaryTextColor': '#1f2937', 'lineColor': '#475569' }}}%%
flowchart LR
    subgraph OCP["Private OpenShift Cluster (openshift-operators)"]
        SUB["OLM Subscription<br/>google-cloud-cluster-services-for-openshift-telemetry<br/>(certified-operators / stable)"]:::subscription
        OP["Telemetry Operator Pod<br/>(workloadagent-operator)"]:::operator
        TC["TelemetryConfig CR<br/>(telemetryconfig)"]:::cr
        SEC["K8s Secret<br/>(telemetry-agent-sa)"]:::secret
        WLM_CM["ConfigMap: wlm-cluster-environment<br/>(namespace: workloadmanager)"]:::config
    end

    subgraph GCP["Google Cloud Platform"]
        GCE["Compute Engine API<br/>(roles/compute.viewer)"]:::compute
        WLM["Workload Manager API & Data Warehouse<br/>(roles/workloadmanager.insightWriter)"]:::wlm
        LOG["Cloud Logging API<br/>(roles/logging.logWriter)"]:::logging
    end

    SUB --> OP
    TC --> OP
    SEC --> OP
    WLM_CM -. "environment: production" .-> OP
    OP -- "Collects VM & cluster configuration (every 30m)" --> GCE
    OP -- "Writes OpenShift telemetry insights" --> WLM
    OP -- "Streams google-cloud-workload-agent logs" --> LOG

    classDef subscription fill:#ffe4e6,stroke:#e11d48,stroke-width:2px,color:#881337
    classDef operator fill:#e0e7ff,stroke:#4f46e5,stroke-width:2px,color:#312e81
    classDef cr fill:#ccfbf1,stroke:#0d9488,stroke-width:2px,color:#134e4a
    classDef secret fill:#f3e8ff,stroke:#9333ea,stroke-width:2px,color:#3b0764
    classDef config fill:#fef3c7,stroke:#d97706,stroke-width:2px,color:#78350f
    classDef compute fill:#dcfce7,stroke:#16a34a,stroke-width:2px,color:#14532d
    classDef wlm fill:#dbeafe,stroke:#2563eb,stroke-width:2px,color:#1e3a8a
    classDef logging fill:#ffedd5,stroke:#ea580c,stroke-width:2px,color:#7c2d12

    style OCP fill:#fff1f2,stroke:#fb7185,stroke-width:1.5px,color:#9f1239
    style GCP fill:#f0f9ff,stroke:#38bdf8,stroke-width:1.5px,color:#0c4a6e
```

---

## Directory Structure

```text
workload-manager/
├── README.md                                   # Phase 3 overview, architecture & quickstart
├── sync-to-bastion.sh                          # Copies workload-manager/ to ~/ocp-setup/ on Bastion VM
├── docs/
│   └── workload-manager-telemetry-guide.md     # Complete step-by-step guide, WIF option & WLM Console evaluation
├── manifests/
│   ├── 01-telemetry-subscription.yaml          # OLM Subscription (certified-operators / stable)
│   ├── 02-telemetry-config.yaml                # TelemetryConfig CR (telemetryconfig in openshift-operators)
│   └── 03-wlm-production-env.yaml              # Namespace workloadmanager + ConfigMap wlm-cluster-environment
└── scripts/
    ├── 01-prereq-wlm-iam.sh                    # Enables Workload Manager API, creates SA, binds 3 IAM roles & K8s secret
    ├── 02-deploy-telemetry-operator.sh         # Installs Operator Subscription, waits for CSV Succeeded, applies TelemetryConfig
    ├── 03-trigger-and-verify.sh                # Verifies operator pod, triggers immediate collection & checks Cloud Logging
    └── 04-cleanup-phase3.sh                    # Removes TelemetryConfig, Operator Subscription/CSV, K8s Secret & GCP SA
```

---

## Quickstart

### 1. Sync Phase 3 Files to the Bastion VM (Run on Local Workstation)
*(Note: `04-bastion-setup.sh` also copies `workload-manager/` automatically during initial setup. Use `sync-to-bastion.sh` anytime to push updates).*
```bash
./workload-manager/sync-to-bastion.sh
```

### 2. SSH into the Bastion VM
```bash
./scripts/06-access-and-test.sh ssh
```

### 3. Deploy & Verify the Telemetry Operator (Run Inside Bastion VM)
```bash
cd ~/ocp-setup/workload-manager
./scripts/01-prereq-wlm-iam.sh
./scripts/02-deploy-telemetry-operator.sh
./scripts/03-trigger-and-verify.sh
```

### 4. Cleanup Phase 3 (Optional, Run Inside Bastion VM)
```bash
cd ~/ocp-setup/workload-manager
./scripts/04-cleanup-phase3.sh
```

---

## Documentation

- [**Phase 3 Complete Step-by-Step Guide (`docs/workload-manager-telemetry-guide.md`)**](docs/workload-manager-telemetry-guide.md)

---

## Screenshot: Google Cloud Workload Manager OpenShift Evaluation

![Google Cloud Workload Manager OpenShift Evaluation Report](../docs/images/04-workload-manager-evaluation.png)
