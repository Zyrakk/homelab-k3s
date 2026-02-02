# Wazuh en ZCloud - Guía de Despliegue

## Chart utilizado

**morgoved/wazuh-helm v1.0.9**  
URL: https://artifacthub.io/packages/helm/wazuh-helm-morgoved/wazuh

## Prerrequisitos

- k3s funcionando
- cert-manager instalado (el chart puede instalarlo, pero ya lo tienes)
- StorageClass `nfs-shared` disponible
- Helm 3.x instalado

## Verificar prerrequisitos

```bash
# Verificar nodos
kubectl get nodes -o wide

# Verificar que lake está disponible y es x86_64
kubectl get node lake -o jsonpath='{.status.nodeInfo.architecture}'
# Debe mostrar: amd64

# Verificar StorageClass
kubectl get storageclass nfs-shared

# Verificar cert-manager
kubectl get pods -n cert-manager
```

## Instalación

### 1. Añadir repositorio Helm

```bash
helm repo add wazuh-helm https://morgoved.github.io/wazuh-helm
helm repo update
```

### 2. Verificar el chart

```bash
# Ver versiones disponibles
helm search repo wazuh-helm/wazuh --versions

# Ver los values por defecto (opcional, para comparar)
helm show values wazuh-helm/wazuh > wazuh-default-values.yaml
```

### 3. ⚠️ IMPORTANTE: Generar hashes de contraseñas

**ANTES de desplegar**, genera los hashes bcrypt para las contraseñas:

```bash
# Generar hash para el password del admin del indexer
# Ejecuta esto e introduce tu password cuando lo pida
docker run --rm -ti wazuh/wazuh-indexer:4.14.1 \
  bash /usr/share/wazuh-indexer/plugins/opensearch-security/tools/hash.sh
```

Luego actualiza `wazuh-values.yaml`:
- `indexer.cred.password` → tu password en texto plano
- `indexer.cred.passwordHash` → el hash generado

### 4. Crear namespace

```bash
kubectl create namespace wazuh
```

### 5. Desplegar Wazuh

```bash
# Dry-run primero para verificar que todo está bien
helm install wazuh wazuh-helm/wazuh \
  --namespace wazuh \
  -f wazuh-values.yaml \
  --dry-run --debug

# Si todo está OK, instalar
helm install wazuh wazuh-helm/wazuh \
  --namespace wazuh \
  -f wazuh-values.yaml
```

### 6. Verificar despliegue

```bash
# Ver pods (esperar a que todos estén Running)
kubectl get pods -n wazuh -w

# El orden de arranque es:
# 1. Indexer (debe estar Ready primero)
# 2. Manager 
# 3. Dashboard

# Ver eventos si hay problemas
kubectl get events -n wazuh --sort-by='.lastTimestamp'

# Ver logs del indexer
kubectl logs -n wazuh -l app.kubernetes.io/component=indexer -f

# Ver logs del manager
kubectl logs -n wazuh -l app.kubernetes.io/component=manager -f
```

## Configuración DNS (Cloudflare)

Añadir registro A en Cloudflare (**proxy OFF / DNS only**):

```
wazuh.zyrak.cloud -> IP_PUBLICA_ORACLE1
wazuh.zyrak.cloud -> IP_PUBLICA_ORACLE2
```

O si prefieres apuntar solo a lake:
```
wazuh.zyrak.cloud -> IP_PUBLICA_LAKE
```

## Acceso

- **Dashboard**: https://wazuh.zyrak.cloud
- **Usuario**: `admin`
- **Password**: el valor de `indexer.cred.password` en tu values.yaml

## Troubleshooting

### El indexer no arranca (CrashLoopBackOff)

```bash
# Ver logs detallados
kubectl logs -n wazuh -l app.kubernetes.io/component=indexer --tail=200

# Causas comunes:
# 1. "Not yet initialized" - el chart tiene un Job que inicializa el security plugin
# 2. OOMKilled - aumentar memory limits
# 3. Problemas de permisos en NFS
```

### El pod está en Pending

```bash
# Verificar eventos
kubectl describe pod -n wazuh <nombre-pod>

# Causas comunes:
# - nodeSelector no matchea (verificar que lake existe y está Ready)
# - PVC en Pending (problema con NFS provisioner)
# - Recursos insuficientes en lake
```

### Problemas de PVC con NFS

```bash
# Verificar PVCs
kubectl get pvc -n wazuh

# Si están en Pending, verificar el provisioner
kubectl get pods -A | grep nfs

# Verificar que el NFS server está accesible desde lake
ssh lake "showmount -e 10.10.0.2"
```

### El Job de inicialización falla

```bash
# Ver jobs
kubectl get jobs -n wazuh

# Ver logs del job
kubectl logs -n wazuh job/<nombre-job>
```

## Actualización

```bash
helm upgrade wazuh wazuh-helm/wazuh \
  --namespace wazuh \
  -f wazuh-values.yaml
```

## Desinstalación

```bash
# Eliminar release
helm uninstall wazuh -n wazuh

# Eliminar PVCs (⚠️ ESTO BORRA LOS DATOS!)
kubectl delete pvc -n wazuh --all

# Eliminar namespace
kubectl delete namespace wazuh
```

## Notas importantes

### 1. Arquitectura ARM64

- **Indexer, Manager, Dashboard**: Solo x86_64 → deben correr en `lake`
- **Agent**: Tiene imagen ARM64 (`wazuh/wazuh-agent:4.14.1`) → puede correr en todos los nodos

### 2. Habilitar agentes después

Una vez que el stack funcione, edita el values.yaml:

```yaml
agent:
  enabled: true
  nodeSelector: {}  # Vacío para que corra en todos los nodos
  tolerations:
    - operator: Exists  # Tolerar cualquier taint
```

Y actualiza:
```bash
helm upgrade wazuh wazuh-helm/wazuh -n wazuh -f wazuh-values.yaml
```

### 3. Recursos del Intel N150

El N150 es limitado. Si hay problemas de rendimiento:
- Reducir `indexer.resources.limits.memory` a 1.5Gi
- Reducir `indexer.env.OPENSEARCH_JAVA_OPTS` a `-Xms512m -Xmx768m`

### 4. Backup

Los datos están en el NFS de raspberry. Asegúrate de tener backup de:
- `/mnt/nfs/shared/wazuh-*` (los PVCs)