apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: cymbal-gcp-secrets
  namespace: cymbal-stateful
spec:
  provider: gcp
  # Note: spec.secretObjects is intentionally omitted (per Google Cloud Workload Manager
  # security best practices) so secrets are mounted exclusively in node tmpfs memory
  # (/mnt/secrets-store) and never synced to etcd as native Kubernetes Secret objects.
  parameters:
    auth: provider-adc
    secrets: |
      - resourceName: "projects/${PROJECT_ID}/secrets/${PREFIX}-cymbal-db-password/versions/latest"
        path: "db-password.txt"
      - resourceName: "projects/${PROJECT_ID}/secrets/${PREFIX}-cymbal-api-key/versions/latest"
        path: "cymbal-api-key.txt"
