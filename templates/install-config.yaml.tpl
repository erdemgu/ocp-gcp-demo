additionalTrustBundlePolicy: Proxyonly
apiVersion: v1
credentialsMode: Passthrough
baseDomain: ${BASE_DOMAIN}
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
${OS_IMAGE_BLOCK}controlPlane:
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
${OS_IMAGE_BLOCK}metadata:
  name: ${CLUSTER_NAME}
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: ${VPC_CIDR}
  networkType: OVNKubernetes
  serviceNetwork:
  - 172.30.0.0/16
platform:
  gcp:
    firewallRulesManagement: Managed
    projectID: ${PROJECT_ID}
    region: ${REGION}
    defaultMachinePlatform:
      secureBoot: ${SECURE_BOOT_MODE}
    network: ${VPC_NAME}
    controlPlaneSubnet: ${SUBNET_CONTROL_PLANE}
    computeSubnet: ${SUBNET_WORKER}
publish: Internal
pullSecret: '${PULL_SECRET_CONTENT}'
sshKey: |
  ${SSH_PUB_KEY}
