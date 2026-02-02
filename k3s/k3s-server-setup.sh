#!/bin/bash
#===============================================================================
# K3S SERVER SETUP - Control Plane
# Instala k3s server en el N150 (servidor central)
#
# USO: sudo ./k3s-server-setup.sh
#===============================================================================

set -euo pipefail

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuración
K3S_VERSION="v1.31.4+k3s1"  # Versión estable LTS
NODE_IP="10.10.0.1"          # IP del nodo en la VPN
CLUSTER_CIDR="10.42.0.0/16"  # Red de pods
SERVICE_CIDR="10.43.0.0/16"  # Red de servicios

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

check_existing() {
    if systemctl is-active --quiet k3s 2>/dev/null; then
        echo ""
        log_warn "K3s ya está instalado y corriendo"
        read -p "¿Reinstalar? Esto eliminará el cluster actual (y/N): " response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            log_info "Operación cancelada"
            exit 0
        fi
        log_info "Desinstalando k3s existente..."
        /usr/local/bin/k3s-uninstall.sh 2>/dev/null || true
        sleep 3
    fi
}

check_wireguard() {
    if ! ip link show wg0 &>/dev/null; then
        log_error "WireGuard (wg0) no está activo. Configúralo primero."
    fi
    log_ok "WireGuard activo"
}

#===============================================================================
# PREPARAR SISTEMA
#===============================================================================
prepare_system() {
    log_info "Preparando sistema..."
    
    # Deshabilitar swap (k3s lo requiere)
    swapoff -a 2>/dev/null || true
    sed -i '/swap/d' /etc/fstab 2>/dev/null || true
    
    # Cargar módulos necesarios
    modprobe br_netfilter 2>/dev/null || true
    modprobe overlay 2>/dev/null || true
    
    # Configurar sysctl para k8s
    cat > /etc/sysctl.d/k3s.conf << EOF
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
    sysctl --system > /dev/null 2>&1
    
    log_ok "Sistema preparado"
}

#===============================================================================
# INSTALAR K3S SERVER
#===============================================================================
install_k3s_server() {
    log_info "Instalando k3s server ${K3S_VERSION}..."
    
    # Instalar k3s con configuración personalizada
    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${K3S_VERSION}" sh -s - server \
        --node-ip "${NODE_IP}" \
        --advertise-address "${NODE_IP}" \
        --flannel-iface wg0 \
        --cluster-cidr "${CLUSTER_CIDR}" \
        --service-cidr "${SERVICE_CIDR}" \
        --disable servicelb \
        --disable traefik \
        --write-kubeconfig-mode 644 \
        --tls-san "${NODE_IP}" \
        --tls-san "$(hostname)"
    
    log_ok "K3s server instalado"
}

#===============================================================================
# ESPERAR A QUE K3S ESTÉ LISTO
#===============================================================================
wait_for_k3s() {
    log_info "Esperando a que k3s esté listo..."
    
    local max_attempts=60
    local attempt=0
    
    while [[ $attempt -lt $max_attempts ]]; do
        if kubectl get nodes &>/dev/null; then
            log_ok "K3s está listo"
            return 0
        fi
        attempt=$((attempt + 1))
        echo -n "."
        sleep 2
    done
    
    log_error "K3s no arrancó correctamente. Revisa: journalctl -u k3s"
}

#===============================================================================
# CONFIGURAR KUBECTL PARA USUARIO
#===============================================================================
configure_kubectl() {
    log_info "Configurando kubectl..."
    
    # Para root
    mkdir -p /root/.kube
    cp /etc/rancher/k3s/k3s.yaml /root/.kube/config
    
    # Para el usuario actual (si no es root)
    if [[ -n "${SUDO_USER:-}" ]]; then
        USER_HOME=$(eval echo "~${SUDO_USER}")
        mkdir -p "${USER_HOME}/.kube"
        cp /etc/rancher/k3s/k3s.yaml "${USER_HOME}/.kube/config"
        sed -i "s/127.0.0.1/${NODE_IP}/g" "${USER_HOME}/.kube/config"
        chown -R "${SUDO_USER}:${SUDO_USER}" "${USER_HOME}/.kube"
    fi
    
    # Alias útiles
    cat >> /etc/profile.d/k3s.sh << 'EOF'
alias k='kubectl'
alias kgp='kubectl get pods -A'
alias kgn='kubectl get nodes'
alias kgs='kubectl get svc -A'
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
EOF
    
    log_ok "kubectl configurado"
}

#===============================================================================
# OBTENER TOKEN PARA WORKERS
#===============================================================================
get_join_token() {
    log_info "Obteniendo token para workers..."
    
    K3S_TOKEN=$(cat /var/lib/rancher/k3s/server/node-token)
    
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                    TOKEN PARA WORKERS                           ${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}Guarda este token, lo necesitarás para unir los workers:${NC}"
    echo ""
    echo "$K3S_TOKEN"
    echo ""
    
    # Guardar token en archivo
    echo "$K3S_TOKEN" > /etc/rancher/k3s/worker-token
    chmod 600 /etc/rancher/k3s/worker-token
    
    log_ok "Token guardado en /etc/rancher/k3s/worker-token"
}

#===============================================================================
# ETIQUETAR NODO CONTROL PLANE
#===============================================================================
label_control_plane() {
    log_info "Etiquetando nodo control plane..."
    
    # Obtener nombre del nodo
    NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
    
    # Etiquetar como control plane
    kubectl label node "$NODE_NAME" node-role.kubernetes.io/control-plane=true --overwrite
    kubectl label node "$NODE_NAME" role=control-plane --overwrite
    
    # Taint para evitar que pods normales corran aquí (opcional)
    # kubectl taint nodes "$NODE_NAME" node-role.kubernetes.io/control-plane:NoSchedule --overwrite
    
    log_ok "Nodo etiquetado: $NODE_NAME"
}

#===============================================================================
# INFORME FINAL
#===============================================================================
final_report() {
    K3S_TOKEN=$(cat /var/lib/rancher/k3s/server/node-token)
    
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}✅ K3S SERVER INSTALADO CORRECTAMENTE${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    echo -e "${YELLOW}Estado del cluster:${NC}"
    kubectl get nodes -o wide
    echo ""
    
    echo -e "${YELLOW}Información del servidor:${NC}"
    echo "  IP del servidor:  ${NODE_IP}"
    echo "  Puerto API:       6443"
    echo "  Versión k3s:      ${K3S_VERSION}"
    echo "  Kubeconfig:       /etc/rancher/k3s/k3s.yaml"
    echo ""
    
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}COMANDOS PARA UNIR WORKERS:${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "Copia el script k3s-agent-setup.sh a cada worker y ejecuta:"
    echo ""
    echo -e "${YELLOW}En Raspberry:${NC}"
    echo "  sudo ./k3s-agent-setup.sh raspberry 10.10.0.2"
    echo ""
    echo -e "${YELLOW}En Oracle 1:${NC}"
    echo "  sudo ./k3s-agent-setup.sh oracle1 10.10.0.3"
    echo ""
    echo -e "${YELLOW}En Oracle 2:${NC}"
    echo "  sudo ./k3s-agent-setup.sh oracle2 10.10.0.4"
    echo ""
    
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}TOKEN (también en /etc/rancher/k3s/worker-token):${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "$K3S_TOKEN"
    echo ""
    
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}COMANDOS ÚTILES:${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  kubectl get nodes         # Ver nodos"
    echo "  kubectl get pods -A       # Ver todos los pods"
    echo "  k3s kubectl get nodes     # Alternativa directa"
    echo "  journalctl -u k3s -f      # Ver logs de k3s"
    echo ""
}

#===============================================================================
# MAIN
#===============================================================================
main() {
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║          K3S SERVER SETUP - Control Plane                  ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    check_root
    check_existing
    check_wireguard
    prepare_system
    install_k3s_server
    wait_for_k3s
    configure_kubectl
    get_join_token
    label_control_plane
    final_report
}

main "$@"