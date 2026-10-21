apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: filestore-regional-csi
provisioner: filestore.csi.storage.gke.io
volumeBindingMode: Immediate
allowVolumeExpansion: true
reclaimPolicy: Delete
parameters:
  # Enterprise tier deploys a Regional (Multi-Zone HA) Cloud Filestore instance
  tier: enterprise
  network: "projects/${PROJECT_ID}/global/networks/${VPC_NAME}"
  connect-mode: PRIVATE_SERVICE_ACCESS
