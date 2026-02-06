# Wazuh on ZCloud - Deployment Guide

## Overview

Wazuh SIEM deployment on k3s hybrid cluster using the morgoved/wazuh-helm chart.

**Chart**: [morgoved/wazuh-helm v1.0.9](https://artifacthub.io/packages/helm/wazuh-helm-morgoved/wazuh)

## Architecture Notes

| Component | Architecture | Node |
|-----------|-------------|------|
| Indexer (OpenSearch) | x86_64 only | lake |
| Manager | x86_64 only | lake |
| Dashboard | x86_64 only | lake |
| Agent | x86_64 + ARM64 | all nodes |

## Prerequisites

- k3s cluster running
- cert-manager installed
- StorageClass `nfs-nvme` available
- Helm 3.x installed

```bash
# Verify prerequisites
kubectl get nodes -o wide
kubectl get node lake -o jsonpath='{.status.nodeInfo.architecture}'  # Should be: amd64
kubectl get storageclass nfs-nvme
kubectl get pods -n cert-manager
```

## File Structure

```
wazuh-stack/
├── README.md
├── wazuh-secrets.yaml.example  # Template (commit this)
├── wazuh-secrets.yaml          # Actual secrets (DO NOT commit - add to .gitignore)
└── wazuh-values.yaml           # Helm values (safe to commit)
```

## Installation

### 1. Add Helm Repository

```bash
helm repo add wazuh-helm https://morgoved.github.io/wazuh-helm
helm repo update
```

### 2. Generate Password Hashes

Generate bcrypt hashes for your passwords:

```bash
docker run --rm -ti wazuh/wazuh-indexer:4.14.1 \
  bash /usr/share/wazuh-indexer/plugins/opensearch-security/tools/hash.sh
```

Run this command for each password you need to hash (indexer admin, dashboard).

### 3. Create Secrets File

```bash
# Copy the template
cp wazuh-secrets.yaml.example wazuh-secrets.yaml

# Edit with your actual values
vim wazuh-secrets.yaml
```

**Important**: The `DASHBOARD_USERNAME` must be `kibanaserver` - it's a reserved OpenSearch internal user with special permissions required by the dashboard.

### 4. Deploy

```bash
# Create namespace
kubectl create namespace wazuh

# Apply secrets first
kubectl apply -f wazuh-secrets.yaml

# Dry-run to verify
helm install wazuh wazuh-helm/wazuh \
  --namespace wazuh \
  -f wazuh-values.yaml \
  --dry-run --debug

# Install
helm install wazuh wazuh-helm/wazuh \
  --namespace wazuh \
  -f wazuh-values.yaml
```

### 5. Verify Deployment

```bash
# Watch pods (startup order: Indexer → Manager → Dashboard)
kubectl get pods -n wazuh -w

# Check events if issues occur
kubectl get events -n wazuh --sort-by='.lastTimestamp'

# View logs
kubectl logs -n wazuh -l app=wazuh-indexer -f
kubectl logs -n wazuh -l app=wazuh-manager -f
kubectl logs -n wazuh -l app=wazuh-dashboard -f
```

## DNS Configuration (Cloudflare)

Add A record with **proxy OFF** (DNS only):

```
wazuh.zyrak.cloud → PUBLIC_IP_ORACLE1
wazuh.zyrak.cloud → PUBLIC_IP_ORACLE2
```

## Access

| | |
|---|---|
| **URL** | https://wazuh.zyrak.cloud |
| **Username** | admin |
| **Password** | Value of `INDEXER_PASSWORD` in wazuh-secrets.yaml |

## Upgrade

```bash
# Update secrets if needed
kubectl apply -f wazuh-secrets.yaml

# Upgrade release
helm upgrade wazuh wazuh-helm/wazuh \
  --namespace wazuh \
  -f wazuh-values.yaml
```

## Uninstall

```bash
# Remove Helm release
helm uninstall wazuh -n wazuh

# Delete PVCs (⚠️ THIS DELETES ALL DATA)
kubectl delete pvc -n wazuh --all

# Delete secrets
kubectl delete secret -n wazuh --all

# Delete namespace
kubectl delete namespace wazuh
```

## Enabling Agents

After the stack is running, enable agents in `wazuh-values.yaml`:

```yaml
agent:
  enabled: true
  nodeSelector: {}  # Empty to run on all nodes
  tolerations:
    - operator: Exists  # Tolerate all taints
```

Then upgrade:

```bash
helm upgrade wazuh wazuh-helm/wazuh -n wazuh -f wazuh-values.yaml
```

## Troubleshooting

### Dashboard in CrashLoopBackOff

```bash
kubectl logs -n wazuh -l app=wazuh-dashboard --tail=100
```

**Common causes**:
- Wrong dashboard username (must be `kibanaserver`)
- Password hash mismatch
- Indexer not ready yet

### Indexer not starting

```bash
kubectl logs -n wazuh -l app=wazuh-indexer --tail=200
```

**Common causes**:
- OOMKilled → increase memory limits
- NFS permission issues
- Security plugin not initialized (wait for init job)

### Pod stuck in Pending

```bash
kubectl describe pod -n wazuh <pod-name>
```

**Common causes**:
- nodeSelector mismatch (verify `lake` node exists and is Ready)
- PVC in Pending (check NFS provisioner)
- Insufficient resources on lake

### PVC Issues

```bash
kubectl get pvc -n wazuh
kubectl get pods -A | grep nfs
ssh lake "showmount -e 10.10.0.2"
```

### Init Job Failures

```bash
kubectl get jobs -n wazuh
kubectl logs -n wazuh job/<job-name>
```

### Force Cleanup (if helm uninstall fails)

```bash
helm uninstall wazuh -n wazuh --no-hooks || true
kubectl delete all --all -n wazuh --force --grace-period=0
kubectl delete pvc --all -n wazuh
kubectl delete secret --all -n wazuh
kubectl delete configmap --all -n wazuh
kubectl delete certificates --all -n wazuh
kubectl delete issuers --all -n wazuh
```

## Resource Tuning for Intel N150

If experiencing performance issues on the N150:

```yaml
indexer:
  resources:
    limits:
      memory: 1.5Gi
  env:
    OPENSEARCH_JAVA_OPTS: "-Xms512m -Xmx768m -Dlog4j2.formatMsgNoLookups=true"
```

## Backup

Data is stored on the Raspberry Pi NFS. Ensure backups of:

```
/mnt/nfs/nvme/wazuh-*
```
