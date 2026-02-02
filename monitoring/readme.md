# ZCloud Monitoring Stack

Stack de monitorización para el cluster k3s de ZCloud.

## Componentes

| Componente | Versión anterior | Versión actual | Cambios principales |
|------------|------------------|----------------|---------------------|
| Node Exporter | v1.7.0 | **v1.10.2** | Bugfix métricas Zswap |
| Kube State Metrics | v2.10.1 | **v2.17.0** | Nuevos endpoints livez/readyz, métricas deletion_timestamp |
| VictoriaMetrics | v1.96.0 | **v1.122.0** | LTS release, security fixes, mejoras rendimiento |
| Grafana | v10.3.1 | **v12.3.1** | Dynamic dashboards, nuevas visualizaciones |

## Arquitectura

```
┌─────────────────────────────────────────────────────────────────┐
│                         CLUSTER K3S                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐        │
│  │   lake   │  │ oracle1  │  │ oracle2  │  │raspberry │        │
│  │  (N150)  │  │          │  │          │  │   (Pi5)  │        │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘        │
│       │             │             │             │               │
│       └──────────┬──┴─────────────┴─────────────┘               │
│                  │                                               │
│           ┌──────▼──────┐                                       │
│           │Node Exporter│  (DaemonSet - 1 por nodo)             │
│           │    :9100    │                                       │
│           └──────┬──────┘                                       │
│                  │                                               │
│    ┌─────────────┼─────────────┐                                │
│    │             │             │                                │
│    ▼             ▼             ▼                                │
│ ┌──────┐  ┌─────────────┐  ┌──────────────────┐                │
│ │ KSM  │  │VictoriaMetrics│  │     Grafana      │               │
│ │:8080 │──│    :8428     │◄─│      :3000       │               │
│ └──────┘  │  (scraper)   │  │  (dashboards)    │               │
│           │  (storage)   │  │                  │               │
│           │   50Gi NFS   │  │    5Gi NFS       │               │
│           └──────────────┘  └──────────────────┘                │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

## Actualización (desde versiones anteriores)

Si ya tienes el stack desplegado, actualiza así:

```bash
# Rolling update - los pods se recrearán con las nuevas imágenes
zcloud apply 01-node-exporter.yaml
zcloud apply 02-victoriametrics.yaml
zcloud apply 03-grafana.yaml
zcloud apply 04-kube-state-metrics.yaml

# Verificar que los pods se actualizan
zcloud k get pods -n monitoring -w

# Verificar versiones desplegadas
zcloud k get pods -n monitoring -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
```

**Nota sobre VictoriaMetrics:** La actualización de v1.96.0 a v1.122.0 es compatible. Los datos existentes se mantendrán.

## Despliegue inicial

### Opción 1: Con zcloud (recomendado)

```bash
# Aplicar en orden
zcloud apply 00-namespace.yaml
zcloud apply 01-node-exporter.yaml
zcloud apply 02-victoriametrics.yaml
zcloud apply 03-grafana.yaml
zcloud apply 04-kube-state-metrics.yaml

# O todo de una vez
for f in 0*.yaml; do zcloud apply $f; done
```

### Opción 2: Con kubectl directo

```bash
kubectl apply -f 00-namespace.yaml
kubectl apply -f 01-node-exporter.yaml
kubectl apply -f 02-victoriametrics.yaml
kubectl apply -f 03-grafana.yaml
kubectl apply -f 04-kube-state-metrics.yaml
```

## Verificar despliegue

```bash
# Ver pods
zcloud k get pods -n monitoring

# Output esperado:
# NAME                                  READY   STATUS    RESTARTS   AGE
# node-exporter-xxxxx                   1/1     Running   0          1m
# node-exporter-yyyyy                   1/1     Running   0          1m
# node-exporter-zzzzz                   1/1     Running   0          1m
# node-exporter-wwwww                   1/1     Running   0          1m
# victoriametrics-xxxxx                 1/1     Running   0          1m
# grafana-xxxxx                         1/1     Running   0          1m
# kube-state-metrics-xxxxx              1/1     Running   0          1m

# Ver PVCs
zcloud k get pvc -n monitoring

# Verificar versiones
zcloud k get deploy,ds -n monitoring -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.spec.template.spec.containers[0].image}{"\n"}{end}'
```

## Acceso

### Port-forward temporal (para probar)

```bash
# Grafana
zcloud port-forward grafana.monitoring.svc 3000:3000
# Abrir http://localhost:3000

# VictoriaMetrics UI
zcloud port-forward victoriametrics.monitoring.svc 8428:8428
# Abrir http://localhost:8428/vmui
```

### Credenciales Grafana

| Usuario | Password |
|---------|----------|
| admin | zcloud-admin-2026 |

**⚠️ Cambiar la contraseña después del primer login**

## Dashboards incluidos

1. **ZCloud - Node Overview** (`zcloud-nodes`)
   - CPU usage por nodo
   - Memory usage por nodo
   - Disk usage (root)
   - Network I/O
   - Disk I/O
   - Node status (UP/DOWN)

2. **ZCloud - Kubernetes Cluster** (`zcloud-k8s`)
   - Total nodes/pods
   - Pods not running
   - CPU por namespace
   - Memory por namespace
   - Network I/O por namespace

## Métricas disponibles

### Node Exporter (por nodo)
- `node_cpu_seconds_total` - CPU
- `node_memory_*` - RAM
- `node_filesystem_*` - Disco
- `node_network_*` - Red
- `node_disk_*` - I/O disco
- `node_load*` - Load average

### Kube State Metrics (objetos K8s)
- `kube_pod_*` - Estado de pods
- `kube_deployment_*` - Deployments
- `kube_node_*` - Nodos
- `kube_pvc_*` - Volúmenes
- `kube_*_deletion_timestamp` - (NUEVO en v2.17) Timestamps de borrado

### cAdvisor (contenedores)
- `container_cpu_*` - CPU por contenedor
- `container_memory_*` - Memory por contenedor
- `container_network_*` - Red por contenedor

## Retención de datos

- **VictoriaMetrics**: 90 días (configurable en `-retentionPeriod`)
- **Grafana**: Dashboards en ConfigMap (persistentes)

## Troubleshooting

### VictoriaMetrics no scrapea

```bash
# Ver targets
curl http://localhost:8428/targets

# Ver config
zcloud k logs -n monitoring deploy/victoriametrics
```

### Grafana no arranca

```bash
# Ver logs
zcloud k logs -n monitoring deploy/grafana

# Verificar permisos del PVC
zcloud k describe pvc grafana-data -n monitoring
```

### Node Exporter no aparece en nodo

```bash
# Verificar DaemonSet
zcloud k get ds -n monitoring

# Ver pods en todos los nodos
zcloud k get pods -n monitoring -o wide
```

## Changelog

### 2026-01-27
- **Node Exporter**: v1.7.0 → v1.10.2
- **Kube State Metrics**: v2.10.1 → v2.17.0
  - Añadido RBAC para EndpointSlices
  - Cambiado healthz → livez/readyz endpoints
- **VictoriaMetrics**: v1.96.0 → v1.122.0 (LTS)
- **Grafana**: v10.3.1 → v12.3.1