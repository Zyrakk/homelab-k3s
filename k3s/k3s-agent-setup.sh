#!/bin/bash
#===============================================================================
# K3S AGENT SETUP - Worker Node
# Instala k3s agent y une el nodo al cluster
#
# USO: sudo ./k3s-agent-setup.sh <nombre_nodo> <ip_nodo>
#
# Ejemplos:
#   sudo ./k3s-agent-setup.sh raspberry 10.10.0.2
#   sudo ./k3s-agent-setup.sh oracle1 10.10.0.3
#   sudo ./k3s-agent-setup.sh oracle2 10.10.0.4
#===============================================================================

set -euo pipefail

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuración del servidor
K3S_SERVER_IP="10.10.0.1"
K3S_SERVER_URL="https://${K3S_SERVER_IP}:6443"
K3S_VERSION="v1.31.4+k3s1"

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

#===============================================================================
# VERIFICACIONES
#===============================================================================
check_args() {
    if [[ $# -lt 2 ]]; then
        echo ""
        echo "USO: $0 <nombre_nodo> <ip_nodo>"
        echo ""
        echo "Ejemplos:"
        echo "  $0 raspberry 10.10.0.2"
        echo "  $0 oracle1 10.10.0.3"
        echo "  $0 oracle2 10.10.0.4"
        echo ""
        exit 1
    fi
    
    NODE_NAME="$1"
    NODE_IP="$2"
    
    log_info "Configurando nodo: ${NODE_NAME} (${NODE_IP})"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Este script debe ejecutarse como root"
    fi
}

check_existing() {
    if systemctl is-active --quiet k3s-agent 2>/dev/null; then
        echo ""
        log_warn "K3s agent ya está instalado y corriendo"
        read -p "¿Reinstalar? (y/N): " response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            log_info "Operación cancelada"
            exit 0
        fi
        log_info "Desinstalando k3s-agent existente..."
        /usr/local/bin/k3s-agent-uninstall.sh 2>/dev/null || true
        sleep 3
    fi
}

check_wireguard() {
    if ! ip link show wg0 &>/dev/null; then
        log_error "WireGuard (wg0) no está activo. Configúralo primero."
    fi
    log_ok "WireGuard activo"
}

check_server_connectivity() {
    log_info "Verificando conectividad con el servidor k3s..."
    
    if ! ping -c 2 -W 3 "${K3S_SERVER_IP}" &>/dev/null; then
        log_error "No se puede alcanzar el servidor k3s en ${K3S_SERVER_IP}"
    fi
    
    log_ok "Servidor k3s alcanzable"
}

#===============================================================================
# OBTENER TOKEN
#===============================================================================
get_token() {
    log_info "Obteniendo token..."
    
    if [[ -n "${K3S_TOKEN:-}" ]]; then
        log_ok "Token proporcionado por variable de entorno"
        return 0
    fi
    
    echo ""
    echo -e "${YELLOW}Introduce el token del servidor k3s:${NC}"
    echo "(Lo encuentras en el servidor en /etc/rancher/k3s/worker-token)"
    echo ""
    read -r K3S_TOKEN
    
    if [[ -z "$K3S_TOKEN" ]]; then
        log_error "Token vacío"
    fi
    
    log_ok "Token recibido"
}

#===============================================================================
# PREPARAR SISTEMA
#===============================================================================
prepare_system() {
    log_info "Preparando sistema..."
    
    # Deshabilitar swap
    swapoff -a 2>/dev/null || true
    sed -i '/swap/d' /etc/fstab 2>/dev/null || true
    
    # Cargar módulos necesarios
    modprobe br_netfilter 2>/dev/null || true
    modprobe overlay 2>/dev/null || true
    
    # Configurar sysctl
    cat > /etc/sysctl.d/k3s.conf << EOF
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
    sysctl --system > /dev/null 2>&1
    
    log_ok "Sistema preparado"
}

#===============================================================================
# INSTALAR K3S AGENT
#===============================================================================
install_k3s_agent() {
    log_info "Instalando k3s agent ${K3S_VERSION}..."
    
    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${K3S_VERSION}" K3S_URL="${K3S_SERVER_URL}" K3S_TOKEN="${K3S_TOKEN}" sh -s - agent \
        --node-name "${NODE_NAME}" \
        --node-ip "${NODE_IP}" \
        --flannel-iface wg0
    
    log_ok "K3s agent instalado"
}

#===============================================================================
# ESPERAR A QUE EL AGENTE ESTÉ LISTO
#===============================================================================
wait_for_agent() {
    log_info "Esperando a que el agente se conecte al cluster..."
    
    local max_attempts=30
    local attempt=0
    
    while [[ $attempt -lt $max_attempts ]]; do
        if systemctl is-active --quiet k3s-agent; then
            # Verificar si el nodo aparece en el cluster (desde el servidor)
            sleep 5
            log_ok "Agente k3s activo"
            return 0
        fi
        attempt=$((attempt + 1))
        echo -n "."
        sleep 2
    done
    
    log_error "El agente no arrancó correctamente. Revisa: journalctl -u k3s-agent"
}

#===============================================================================
# INFORME FINAL
#===============================================================================
final_report() {
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}✅ K3S AGENT INSTALADO CORRECTAMENTE${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    echo -e "${YELLOW}Información del nodo:${NC}"
    echo "  Nombre:     ${NODE_NAME}"
    echo "  IP:         ${NODE_IP}"
    echo "  Servidor:   ${K3S_SERVER_URL}"
    echo ""
    
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}VERIFICACIÓN (ejecutar en el servidor N150):${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  kubectl get nodes"
    echo ""
    echo "El nodo '${NODE_NAME}' debería aparecer en estado 'Ready'"
    echo ""
    
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}ETIQUETAR NODO (ejecutar en el servidor N150):${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    case "${NODE_NAME}" in
        raspberry*)
            echo "  kubectl label node ${NODE_NAME} role=storage --overwrite"
            echo "  kubectl label node ${NODE_NAME} node-role.kubernetes.io/worker=true --overwrite"
            ;;
        oracle*)
            echo "  kubectl label node ${NODE_NAME} role=compute --overwrite"
            echo "  kubectl label node ${NODE_NAME} node-role.kubernetes.io/worker=true --overwrite"
            ;;
        *)
            echo "  kubectl label node ${NODE_NAME} node-role.kubernetes.io/worker=true --overwrite"
            ;;
    esac
    echo ""
    
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}COMANDOS ÚTILES (en este nodo):${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  systemctl status k3s-agent    # Estado del agente"
    echo "  journalctl -u k3s-agent -f    # Ver logs"
    echo "  systemctl restart k3s-agent   # Reiniciar agente"
    echo ""
}

#===============================================================================
# MAIN
#===============================================================================
main() {
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║          K3S AGENT SETUP - Worker Node                     ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    check_args "$@"
    check_root
    check_existing
    check_wireguard
    check_server_connectivity
    get_token
    prepare_system
    install_k3s_agent
    wait_for_agent
    final_report
}

main "$@"