<div align="center">

# k3s Homelab Infrastructure

**Infrastructure as Code for distributed k3s cluster on heterogeneous hardware**

[![k3s](https://img.shields.io/badge/k3s-v1.31.4-orange)](https://k3s.io)
[![Helm](https://img.shields.io/badge/Helm-v3.x-blue)](https://helm.sh)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-v1.31-5bc5ee)](https://kubernetes.io)

</div>

---

## Overview

Distributed k3s cluster running on mixed architecture (x86\_64 + ARM64) nodes interconnected via WireGuard VPN. Includes full observability stack and SIEM.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              WireGuard VPN (10.10.0.0/24)                   │
└──────────────────────────────────────┬──────────────────────────────────────┘
                                       │
        ┌──────────────────────────────┼──────────────────────────────┐
        │                              │                              │
        ▼                              ▼                              ▼
┌───────────────┐          ┌─────────────────┐              ┌───────────────┐
│ LAKE          │          │ ORACLE CLOUD    │              │ RASPBERRY PI  │
│ Intel N150    │          │ 2x ARM VMs      │              │ Pi 5 (ARM64)  │
│ x86_64        │          │                 │              │               │
│ 10.10.0.1     │          │ 10.10.0.21/22   │              │ 10.10.0.2     │
│               │          │                 │              │               │
│ Control Plane │          │ Worker Nodes    │              │ NFS Storage   │
│ + Wazuh Stack │          │                 │              │               │
└───────────────┘          └─────────────────┘              └───────────────┘
```

## Components

| Directory | Description |
|---|---|
| **[wireguard/](wireguard/)** | VPN mesh setup scripts (server + client) |
| **[k3s/](k3s/)** | k3s installation (server/agent setup) |
| **[monitoring/](monitoring/)** | VictoriaMetrics, Grafana, Node Exporter, KSM |
| **[wazuh-stack/](wazuh-stack/)** | SIEM platform (Indexer, Manager, Dashboard) |

## Tech Stack

- **k3s** v1.31.4 — Lightweight Kubernetes distribution
- **WireGuard** — Layer 3 secure VPN tunnel
- **cert-manager** — Automated TLS certificate management
- **VictoriaMetrics** v1.122.0 — High-performance time series database
- **Grafana** v12.3.1 — Metrics visualization
- **Wazuh** v4.14.1 — Security information and event management
- **NFS** — Shared persistent storage via dynamic provisioning

## Quick Start

### Prerequisites

- 4+ nodes (1 x86\_64 for control plane, ARM64 compatible)
- Fedora/RHEL/CentOS on all nodes
- SSH access between nodes

### 1. Deploy WireGuard VPN

```bash
cd wireguard
sudo ./wg-server-setup.sh              # On control plane node
sudo ./wg-client-setup.sh --server-ip 10.10.0.1  # On each worker
```

### 2. Install k3s Cluster

```bash
cd k3s
sudo ./k3s-server-setup.sh             # On control plane
TOKEN=$(sudo cat /var/lib/rancher/k3s/server/node-token)
sudo ./k3s-agent-setup.sh --server-ip 10.10.0.1 --token $TOKEN  # On workers
```

### 3. Deploy Monitoring Stack

```bash
cd monitoring
kubectl apply -f 00-namespace.yaml
kubectl apply -f 01-node-exporter.yaml
kubectl apply -f 02-victoriametrics.yaml
kubectl apply -f 03-grafana.yaml
kubectl apply -f 04-kube-state-metrics.yaml
```

### 4. Deploy Wazuh SIEM

```bash
cd wazuh-stack
helm repo add wazuh-helm https://morgoved.github.io/wazuh-helm
helm install wazuh wazuh-helm/wazuh -n wazuh -f wazuh-values.yaml --create-namespace
```

### Cluster Status

```bash
kubectl get nodes -o wide
kubectl get pods -A
kubectl get pvc -A
```

## Design Decisions

| Decision | Rationale |
|---|---|
| k3s over full k8s | Lower resource footprint, single binary, embedded SQLite |
| WireGuard over OpenVPN | Smaller codebase, faster performance, modern cryptography |
| VictoriaMetrics over Prometheus | Better compression, lower memory usage, PromQL compatible |
| x86\_64 control plane | Wazuh components only available in x86\_64 |
| NFS on Pi 5 | Cost-effective always-on storage node |

## License

MIT