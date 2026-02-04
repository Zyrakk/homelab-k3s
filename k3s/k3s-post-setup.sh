#!/bin/bash
#===============================================================================
# K3S POST-SETUP - Labels y NFS Provisioner
# Configura labels de nodos y instala NFS provisioner
#
# USO: sudo ./k3s-post-setup.sh
#
# EJECUTAR EN EL N150 (servidor) después de unir todos los workers
#===============================================================================

set -euo pipefail

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuración NFS
NFS_SERVER="10.10.0.2"           # IP de la Raspberry en VPN
NFS_PATH_ORACLE1="/mnt/nfs/oracle1"
NFS_PATH_ORACLE2="/mnt/nfs/oracle2"
NFS_PATH_SHARED="/mnt/nfs/shared"
NFS_PATH_NVME="/mnt/nvme"

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

#===============================================================================
# VERIFICACIONES
#===============================================================================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Este script debe ejecutarse como root"
    fi
}

check_cluster() {
    log_info "Verificando cluster..."
    
    if ! kubectl get nodes &>/dev/null; then
        log_error "No se puede conectar al cluster. ¿Está k3s corriendo?"
    fi
    
    NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
    log_info "Nodos en el cluster: ${NODE_COUNT}"
    
    kubectl get nodes
    echo ""
}

check_all_nodes_ready() {
    log_info "Verificando que todos los nodos estén Ready..."
    
    NOT_READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -v "Ready" | wc -l || echo "0")
    
    if [[ "$NOT_READY" -gt 0 ]]; then
        log_warn "Hay nodos que no están Ready:"
        kubectl get nodes | grep -v "Ready" || true
        echo ""
        read -p "¿Continuar de todas formas? (y/N): " response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            exit 1
        fi
    else
        log_ok "Todos los nodos están Ready"
    fi
}

#===============================================================================
# ETIQUETAR NODOS
#===============================================================================
label_nodes() {
    log_info "Etiquetando nodos..."
    
    # Obtener lista de nodos
    NODES=$(kubectl get nodes --no-headers -o custom-columns=":metadata.name")
    
    for node in $NODES; do
        case "$node" in
            raspberry*|raspi*|pi*)
                log_info "Etiquetando $node como storage (Raspberry)"
                kubectl label node "$node" role=storage --overwrite
                kubectl label node "$node" node-role.kubernetes.io/worker=true --overwrite
                kubectl label node "$node" storage-type=hdd --overwrite
                ;;
            oracle1*|oci1*)
                log_info "Etiquetando $node como compute (Oracle 1)"
                kubectl label node "$node" role=compute --overwrite
                kubectl label node "$node" node-role.kubernetes.io/worker=true --overwrite
                kubectl label node "$node" oracle-node=oci1 --overwrite
                ;;
            oracle2*|oci2*)
                log_info "Etiquetando $node como compute (Oracle 2)"
                kubectl label node "$node" role=compute --overwrite
                kubectl label node "$node" node-role.kubernetes.io/worker=true --overwrite
                kubectl label node "$node" oracle-node=oci2 --overwrite
                ;;
            lake*|n150*)
                log_info "Etiquetando $node como control-plane"
                kubectl label node "$node" role=control-plane --overwrite
                ;;
            *)
                log_info "Nodo $node sin etiqueta específica, saltando..."
                ;;
        esac
    done
    
    log_ok "Nodos etiquetados"
}

#===============================================================================
# INSTALAR HELM (si no está)
#===============================================================================
install_helm() {
    if command -v helm &>/dev/null; then
        log_ok "Helm ya instalado"
        return 0
    fi
    
    log_info "Instalando Helm..."
    
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    
    log_ok "Helm instalado"
}

#===============================================================================
# CREAR NAMESPACE PARA STORAGE
#===============================================================================
create_storage_namespace() {
    log_info "Creando namespace para storage..."
    
    kubectl create namespace nfs-provisioner --dry-run=client -o yaml | kubectl apply -f -
    
    log_ok "Namespace nfs-provisioner creado"
}

#===============================================================================
# INSTALAR NFS SUBDIR EXTERNAL PROVISIONER
#===============================================================================
install_nfs_provisioner() {
    log_info "Instalando NFS Subdir External Provisioner..."
    
    # Añadir repo de helm
    helm repo add nfs-subdir-external-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/ 2>/dev/null || true
    helm repo update
    
    # Instalar provisioner para el volumen compartido (shared)
    log_info "Instalando provisioner para volumen compartido..."
    helm upgrade --install nfs-shared nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
        --namespace nfs-provisioner \
        --set nfs.server="${NFS_SERVER}" \
        --set nfs.path="${NFS_PATH_SHARED}" \
        --set storageClass.name=nfs-shared \
        --set storageClass.defaultClass=true \
        --set storageClass.reclaimPolicy=Retain \
        --set storageClass.archiveOnDelete=true

    # Instalar provisioner para NVMe (nfs-nvme)
    log_info "Instalando provisioner para NVMe..."
    helm upgrade --install nfs-nvme nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
        --namespace nfs-provisioner \
        --set nfs.server="${NFS_SERVER}" \
        --set nfs.path="${NFS_PATH_NVME}" \
        --set storageClass.name=nfs-nvme \
        --set storageClass.defaultClass=false \
        --set storageClass.reclaimPolicy=Retain \
        --set storageClass.archiveOnDelete=true
    
    log_ok "NFS provisioner instalado"
}

#===============================================================================
# CREAR STORAGE CLASSES ADICIONALES
#===============================================================================
create_storage_classes() {
    log_info "Configurando StorageClasses..."
    
    # Marcar nfs-shared como default (ya lo hace helm, pero por si acaso)
    kubectl patch storageclass nfs-shared -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' 2>/dev/null || true
    
    # Marcar local-path como no-default
    kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' 2>/dev/null || true

    # Asegurar nfs-nvme como no-default
    kubectl patch storageclass nfs-nvme -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' 2>/dev/null || true
    
    log_ok "StorageClasses configuradas"
}

#===============================================================================
# VERIFICAR INSTALACIÓN
#===============================================================================
verify_installation() {
    log_info "Verificando instalación..."
    
    echo ""
    echo -e "${YELLOW}Nodos y roles:${NC}"
    kubectl get nodes -o custom-columns="NAME:.metadata.name,STATUS:.status.conditions[-1].type,ROLE:.metadata.labels.role" || true
    echo ""
    
    echo -e "${YELLOW}StorageClasses:${NC}"
    kubectl get storageclass || true
    echo ""
    
    echo -e "${YELLOW}Pods del provisioner:${NC}"
    kubectl get pods -n nfs-provisioner || true
    echo ""
}

#===============================================================================
# CREAR PVC DE PRUEBA
#===============================================================================
test_storage() {
    log_info "Creando PVC de prueba..."
    
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-nfs-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: nfs-shared
  resources:
    requests:
      storage: 100Mi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-nfs-pvc-nvme
  namespace: default
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: nfs-nvme
  resources:
    requests:
      storage: 100Mi
EOF

    sleep 10
    
    echo ""
    echo -e "${YELLOW}Estado de PVCs de prueba:${NC}"
    kubectl get pvc test-nfs-pvc test-nfs-pvc-nvme
    
    PVC_STATUS_SHARED=$(kubectl get pvc test-nfs-pvc -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    PVC_STATUS_NVME=$(kubectl get pvc test-nfs-pvc-nvme -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    
    if [[ "$PVC_STATUS_SHARED" == "Bound" ]]; then
        log_ok "PVC de prueba nfs-shared creado y vinculado correctamente"
    else
        log_warn "PVC nfs-shared en estado: $PVC_STATUS_SHARED (puede tardar unos segundos)"
    fi

    if [[ "$PVC_STATUS_NVME" == "Bound" ]]; then
        log_ok "PVC de prueba nfs-nvme creado y vinculado correctamente"
    else
        log_warn "PVC nfs-nvme en estado: $PVC_STATUS_NVME (puede tardar unos segundos)"
    fi
    
    echo ""
    # Eliminar PVC de prueba automáticamente
    kubectl delete pvc test-nfs-pvc --ignore-not-found
    kubectl delete pvc test-nfs-pvc-nvme --ignore-not-found
    log_ok "PVC de prueba eliminado"
}

#===============================================================================
# INFORME FINAL
#===============================================================================
final_report() {
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}✅ K3S POST-SETUP COMPLETADO${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    echo -e "${YELLOW}Resumen del cluster:${NC}"
    kubectl get nodes -o custom-columns="NAME:.metadata.name,STATUS:.status.conditions[-1].type,ROLE:.metadata.labels.role"
    echo ""
    
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}STORAGE CLASSES DISPONIBLES:${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    kubectl get storageclass
    echo ""
    
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}EJEMPLO - Desplegar en nodos compute (Oracle):${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "spec:"
    echo "  nodeSelector:"
    echo "    role: compute"
    echo ""
    
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}EJEMPLO - Desplegar en nodo storage (Raspberry):${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "spec:"
    echo "  nodeSelector:"
    echo "    role: storage"
    echo ""
}

#===============================================================================
# MAIN
#===============================================================================
main() {
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║          K3S POST-SETUP - Labels & NFS Provisioner         ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    check_root
    check_cluster
    check_all_nodes_ready
    label_nodes
    install_helm
    create_storage_namespace
    install_nfs_provisioner
    create_storage_classes
    verify_installation
    test_storage
    final_report
}

main "$@"
