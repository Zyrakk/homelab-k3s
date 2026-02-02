#!/bin/bash
#===============================================================================
# ZCLOUD CLEANUP SCRIPT
# Prepara los servidores para la instalación limpia de k3s y servicios
#
# USO: ./zcloud-cleanup.sh [--dry-run] [--force]
#   --dry-run  Solo muestra qué se limpiaría, no ejecuta
#   --force    No pide confirmación
#===============================================================================

set -euo pipefail

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

DRY_RUN=false
FORCE=false

# Parse args
for arg in "$@"; do
    case $arg in
        --dry-run) DRY_RUN=true ;;
        --force) FORCE=true ;;
    esac
done

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

run_cmd() {
    if $DRY_RUN; then
        echo -e "${YELLOW}[DRY-RUN]${NC} $1"
    else
        eval "$1"
    fi
}

#===============================================================================
# DETECCIÓN DEL SERVIDOR
#===============================================================================
detect_server() {
    log_info "Detectando tipo de servidor..."
    
    HOSTNAME=$(hostname)
    
    # Detectar por arquitectura y hostname
    ARCH=$(uname -m)
    
    if [[ -f /sys/firmware/devicetree/base/model ]] && grep -qi "raspberry" /sys/firmware/devicetree/base/model 2>/dev/null; then
        SERVER_TYPE="raspberry"
        log_info "Detectado: Raspberry Pi (DAS Server)"
    elif [[ -f /etc/oracle-cloud-agent/agent.yml ]] || grep -qi "oracle" /sys/class/dmi/id/board_vendor 2>/dev/null; then
        SERVER_TYPE="oracle"
        log_info "Detectado: Oracle Cloud Instance"
    elif grep -qi "intel" /proc/cpuinfo && [[ "$ARCH" == "x86_64" ]]; then
        SERVER_TYPE="central"
        log_info "Detectado: Servidor Central (Intel)"
    else
        SERVER_TYPE="unknown"
        log_warn "Tipo de servidor no detectado automáticamente"
    fi
    
    echo ""
    echo "=========================================="
    echo " Hostname: $HOSTNAME"
    echo " Arquitectura: $ARCH"
    echo " Tipo detectado: $SERVER_TYPE"
    echo "=========================================="
    echo ""
}

#===============================================================================
# CONFIRMACIÓN
#===============================================================================
confirm_cleanup() {
    if $FORCE; then
        return 0
    fi
    
    echo -e "${RED}⚠️  ADVERTENCIA: Este script eliminará:${NC}"
    echo "   - Instalaciones de k3s"
    echo "   - Contenedores y datos de Docker/Podman"
    echo "   - Servicios de monitorización (Prometheus, Grafana, etc.)"
    echo "   - Configuraciones de NFS client"
    echo "   - WireGuard completamente (se hace backup)"
    echo "   - UFW se resetea y desactiva"
    echo "   - Paquetes huérfanos y configuraciones residuales"
    echo "   - Logs antiguos (>7 días) y archivos temporales"
    echo ""
    echo -e "${GREEN}SE HARÁ:${NC}"
    echo "   - Actualización completa del sistema (apt/dnf upgrade)"
    echo "   - Limpieza de caché de paquetes"
    echo "   - Limpieza de kernels antiguos"
    echo ""
    echo -e "${BLUE}NO se toca:${NC}"
    echo "   - iptables"
    echo "   - SSH"
    echo ""
    read -p "¿Continuar? (escribe 'YES' para confirmar): " response
    
    if [[ "$response" != "YES" ]]; then
        log_info "Operación cancelada"
        exit 0
    fi
}

#===============================================================================
# LIMPIEZA DE K3S
#===============================================================================
cleanup_k3s() {
    log_info "=== Limpiando K3s ==="
    
    # Uninstall script oficial de k3s
    if [[ -f /usr/local/bin/k3s-uninstall.sh ]]; then
        log_info "Encontrado k3s server, desinstalando..."
        run_cmd "/usr/local/bin/k3s-uninstall.sh || true"
    fi
    
    if [[ -f /usr/local/bin/k3s-agent-uninstall.sh ]]; then
        log_info "Encontrado k3s agent, desinstalando..."
        run_cmd "/usr/local/bin/k3s-agent-uninstall.sh || true"
    fi
    
    # Limpiar residuos
    if [[ -d /etc/rancher ]]; then
        log_info "Limpiando /etc/rancher..."
        run_cmd "rm -rf /etc/rancher"
    fi
    
    if [[ -d /var/lib/rancher ]]; then
        log_info "Limpiando /var/lib/rancher..."
        run_cmd "rm -rf /var/lib/rancher"
    fi
    
    # Limpiar CNI
    if [[ -d /var/lib/cni ]]; then
        log_info "Limpiando CNI..."
        run_cmd "rm -rf /var/lib/cni"
    fi
    
    if [[ -d /etc/cni ]]; then
        run_cmd "rm -rf /etc/cni"
    fi
    
    # Limpiar kubeconfig
    if [[ -f ~/.kube/config ]]; then
        log_info "Limpiando kubeconfig..."
        run_cmd "rm -f ~/.kube/config"
    fi
    
    log_ok "K3s limpiado"
}

#===============================================================================
# LIMPIEZA DE DOCKER
#===============================================================================
cleanup_docker() {
    log_info "=== Limpiando Docker ==="
    
    if command -v docker &> /dev/null; then
        log_info "Docker encontrado, limpiando..."
        
        # Parar todos los contenedores
        CONTAINERS=$(docker ps -aq 2>/dev/null || true)
        if [[ -n "$CONTAINERS" ]]; then
            log_info "Parando contenedores..."
            run_cmd "docker stop \$(docker ps -aq) 2>/dev/null || true"
            run_cmd "docker rm \$(docker ps -aq) 2>/dev/null || true"
        fi
        
        # Limpiar imágenes, volúmenes y networks
        log_info "Limpiando imágenes, volúmenes y networks..."
        run_cmd "docker system prune -af --volumes 2>/dev/null || true"
        
        # Opcional: desinstalar docker
        read -p "¿Desinstalar Docker completamente? (y/N): " remove_docker
        if [[ "$remove_docker" =~ ^[Yy]$ ]]; then
            log_info "Desinstalando Docker..."
            run_cmd "systemctl stop docker docker.socket containerd 2>/dev/null || true"
            run_cmd "apt-get purge -y docker-ce docker-ce-cli containerd.io docker-compose-plugin 2>/dev/null || true"
            run_cmd "dnf remove -y docker-ce docker-ce-cli containerd.io docker-compose-plugin 2>/dev/null || true"
            run_cmd "rm -rf /var/lib/docker /var/lib/containerd"
        fi
    else
        log_info "Docker no encontrado"
    fi
    
    log_ok "Docker limpiado"
}

#===============================================================================
# LIMPIEZA DE PODMAN
#===============================================================================
cleanup_podman() {
    log_info "=== Limpiando Podman ==="
    
    if command -v podman &> /dev/null; then
        log_info "Podman encontrado, limpiando..."
        
        # Parar y eliminar todos los contenedores
        run_cmd "podman stop -a 2>/dev/null || true"
        run_cmd "podman rm -af 2>/dev/null || true"
        run_cmd "podman system prune -af --volumes 2>/dev/null || true"
        
        # Limpiar pods
        run_cmd "podman pod rm -af 2>/dev/null || true"
    else
        log_info "Podman no encontrado"
    fi
    
    log_ok "Podman limpiado"
}

#===============================================================================
# LIMPIEZA DE SERVICIOS DE MONITORIZACIÓN
#===============================================================================
cleanup_monitoring() {
    log_info "=== Limpiando servicios de monitorización ==="
    
    SERVICES_TO_STOP=(
        "prometheus"
        "prometheus-node-exporter"
        "node_exporter"
        "grafana-server"
        "grafana"
        "victoriametrics"
        "vmagent"
        "alertmanager"
        "elasticsearch"
        "kibana"
        "filebeat"
        "wazuh-agent"
        "wazuh-manager"
        "ossec"
    )
    
    for svc in "${SERVICES_TO_STOP[@]}"; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            log_info "Parando $svc..."
            run_cmd "systemctl stop $svc || true"
            run_cmd "systemctl disable $svc || true"
        fi
    done
    
    # Limpiar directorios de datos
    DIRS_TO_CLEAN=(
        "/var/lib/prometheus"
        "/var/lib/grafana"
        "/var/lib/victoriametrics"
        "/var/lib/elasticsearch"
        "/var/ossec"
    )
    
    for dir in "${DIRS_TO_CLEAN[@]}"; do
        if [[ -d "$dir" ]]; then
            log_info "Limpiando $dir..."
            run_cmd "rm -rf $dir"
        fi
    done
    
    log_ok "Servicios de monitorización limpiados"
}

#===============================================================================
# LIMPIEZA DE NFS
#===============================================================================
cleanup_nfs() {
    log_info "=== Limpiando NFS ==="
    
    # Desmontar exports NFS
    NFS_MOUNTS=$(mount | grep "type nfs" | awk '{print $3}' || true)
    if [[ -n "$NFS_MOUNTS" ]]; then
        log_info "Desmontando NFS mounts..."
        for mount_point in $NFS_MOUNTS; do
            run_cmd "umount -f $mount_point 2>/dev/null || true"
        done
    fi
    
    # Limpiar fstab entries de NFS (excepto comentarios)
    if grep -v "^#" /etc/fstab | grep -q "nfs"; then
        log_warn "Hay entradas NFS en /etc/fstab - revisar manualmente"
        grep "nfs" /etc/fstab
    fi
    
    # Si es el servidor NFS (Raspberry), parar el servicio pero NO limpiar exports aún
    if [[ "$SERVER_TYPE" == "raspberry" ]]; then
        log_info "Este es el servidor NFS - parando servicio (exports se configurarán después)"
        run_cmd "systemctl stop nfs-server 2>/dev/null || true"
    fi
    
    log_ok "NFS limpiado"
}

#===============================================================================
# LIMPIEZA DE FIREWALL
#===============================================================================
cleanup_firewall() {
    log_info "=== Firewall ==="
    
    # NUNCA tocar iptables
    log_info "iptables: NO SE TOCA (gestionado manualmente / OCI Security Groups)"
    
    # UFW: resetear y desactivar completamente
    if command -v ufw &> /dev/null; then
        log_info "UFW encontrado - reseteando y desactivando..."
        run_cmd "ufw --force reset"
        run_cmd "ufw disable"
        log_info "UFW desactivado completamente"
    else
        log_info "UFW no instalado"
    fi
    
    log_ok "Firewall procesado (iptables intacto, UFW desactivado)"
}

#===============================================================================
# LIMPIEZA DE INTERFACES DE RED VIRTUALES
#===============================================================================
cleanup_network_interfaces() {
    log_info "=== Limpiando interfaces de red virtuales ==="
    
    # CNI interfaces (de k3s/docker)
    for iface in $(ip link show 2>/dev/null | grep -E "cni|flannel|veth|docker|br-|cali|tunl" | awk -F: '{print $2}' | tr -d ' '); do
        log_info "Eliminando interface $iface..."
        run_cmd "ip link delete $iface 2>/dev/null || true"
    done
    
    # NO tocamos iptables - se gestionan manualmente o por OCI
    log_info "iptables: NO SE TOCA"
    
    log_ok "Interfaces de red virtuales limpiadas"
}

#===============================================================================
# LIMPIEZA DE WIREGUARD (BORRAR COMPLETAMENTE)
#===============================================================================
cleanup_wireguard() {
    log_info "=== Limpiando WireGuard completamente ==="
    
    # Parar interfaces WireGuard activas
    for iface in $(ip link show type wireguard 2>/dev/null | awk -F: '{print $2}' | tr -d ' '); do
        if [[ -n "$iface" ]]; then
            log_info "Bajando interface WireGuard: $iface"
            run_cmd "wg-quick down $iface 2>/dev/null || ip link delete $iface 2>/dev/null || true"
        fi
    done
    
    # Parar servicios de WireGuard
    for wg_service in $(systemctl list-units --type=service --all 2>/dev/null | grep -E "wg-quick|wireguard" | awk '{print $1}'); do
        log_info "Parando servicio: $wg_service"
        run_cmd "systemctl stop $wg_service 2>/dev/null || true"
        run_cmd "systemctl disable $wg_service 2>/dev/null || true"
    done
    
    # Eliminar configuración de WireGuard
    if [[ -d /etc/wireguard ]]; then
        log_info "Eliminando /etc/wireguard..."
        # Backup por si acaso
        if [[ ! $DRY_RUN ]]; then
            run_cmd "cp -r /etc/wireguard /etc/wireguard.backup.$(date +%Y%m%d%H%M%S) 2>/dev/null || true"
        fi
        run_cmd "rm -rf /etc/wireguard/*"
        log_info "Configuración WireGuard eliminada (backup creado en /etc/wireguard.backup.*)"
    else
        log_info "No hay configuración WireGuard en /etc/wireguard"
    fi
    
    log_ok "WireGuard limpiado completamente"
}

#===============================================================================
# ACTUALIZACIÓN Y LIMPIEZA DEL SISTEMA
#===============================================================================
update_and_cleanup_system() {
    log_info "=== Actualizando y limpiando el sistema ==="
    
    if command -v apt-get &> /dev/null; then
        # Debian/Ubuntu/Raspberry Pi OS
        log_info "Sistema basado en APT detectado"
        
        # Limpiar repositorios de Docker (ya no se necesitan tras cleanup)
        if [[ -f /etc/apt/sources.list.d/docker.list ]] || ls /etc/apt/sources.list.d/docker*.list &>/dev/null; then
            log_info "Eliminando repositorios de Docker..."
            run_cmd "rm -f /etc/apt/sources.list.d/docker*.list"
            run_cmd "rm -f /etc/apt/keyrings/docker*.gpg"
            run_cmd "rm -f /usr/share/keyrings/docker*.gpg"
        fi
        
        # Actualizar repositorios
        log_info "Actualizando repositorios..."
        run_cmd "apt-get update"
        
        # Actualizar paquetes
        log_info "Actualizando paquetes instalados..."
        run_cmd "DEBIAN_FRONTEND=noninteractive apt-get upgrade -y"
        
        # Actualización completa (incluye cambios de dependencias)
        log_info "Aplicando dist-upgrade..."
        run_cmd "DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y"
        
        # Eliminar paquetes huérfanos
        log_info "Eliminando paquetes huérfanos..."
        run_cmd "apt-get autoremove -y --purge"
        
        # Limpiar paquetes descargados en caché
        log_info "Limpiando caché de paquetes..."
        run_cmd "apt-get autoclean -y"
        run_cmd "apt-get clean"
        
        # Eliminar kernels antiguos (mantener los 2 más recientes)
        log_info "Limpiando kernels antiguos..."
        run_cmd "apt-get autoremove -y --purge 2>/dev/null || true"
        
        # Limpiar configuraciones residuales de paquetes eliminados
        log_info "Limpiando configuraciones residuales..."
        if dpkg -l | grep -q '^rc'; then
            run_cmd "dpkg -l | grep '^rc' | awk '{print \$2}' | xargs -r dpkg --purge 2>/dev/null || true"
        else
            log_info "No hay configuraciones residuales"
        fi
        
    elif command -v dnf &> /dev/null; then
        # Fedora/RHEL/Oracle Linux
        log_info "Sistema basado en DNF detectado"
        
        # Actualizar repositorios y paquetes
        log_info "Actualizando repositorios y paquetes..."
        run_cmd "dnf upgrade -y --refresh"
        
        # Eliminar paquetes huérfanos
        log_info "Eliminando paquetes huérfanos..."
        run_cmd "dnf autoremove -y"
        
        # Limpiar caché
        log_info "Limpiando caché..."
        run_cmd "dnf clean all"
        
        # Eliminar kernels antiguos (mantener los 2 más recientes)
        log_info "Limpiando kernels antiguos..."
        run_cmd "dnf remove -y --oldinstallonly --setopt installonly_limit=2 2>/dev/null || true"
        
    elif command -v yum &> /dev/null; then
        # CentOS/RHEL antiguo
        log_info "Sistema basado en YUM detectado"
        
        run_cmd "yum update -y"
        run_cmd "yum autoremove -y"
        run_cmd "yum clean all"
        run_cmd "package-cleanup --oldkernels --count=2 -y 2>/dev/null || true"
    fi
    
    # Limpiar logs antiguos (más de 7 días)
    log_info "Limpiando logs antiguos..."
    run_cmd "journalctl --vacuum-time=7d 2>/dev/null || true"
    
    # Limpiar archivos temporales
    log_info "Limpiando archivos temporales..."
    run_cmd "rm -rf /tmp/* 2>/dev/null || true"
    run_cmd "rm -rf /var/tmp/* 2>/dev/null || true"
    
    # Limpiar caché de thumbnails y basura del usuario
    if [[ -d /root/.cache ]]; then
        run_cmd "rm -rf /root/.cache/* 2>/dev/null || true"
    fi
    
    log_ok "Sistema actualizado y limpiado"
}

#===============================================================================
# INFORME FINAL
#===============================================================================
final_report() {
    echo ""
    echo "=========================================="
    echo -e "${GREEN}✅ LIMPIEZA Y ACTUALIZACIÓN COMPLETADA${NC}"
    echo "=========================================="
    echo ""
    echo "Estado del sistema:"
    echo "-------------------"
    echo "Memoria libre: $(free -h | awk '/^Mem:/ {print $4}')"
    echo "Disco libre:   $(df -h / | awk 'NR==2 {print $4}')"
    echo "Kernel:        $(uname -r)"
    echo ""
    echo "Resumen:"
    echo "  - k3s: eliminado"
    echo "  - Docker/Podman: limpiado"
    echo "  - WireGuard: eliminado (backup en /etc/wireguard.backup.*)"
    echo "  - UFW: desactivado"
    echo "  - iptables: INTACTO"
    echo "  - Sistema: ACTUALIZADO"
    echo "  - Paquetes huérfanos: eliminados"
    echo "  - Caché y logs antiguos: limpiados"
    echo ""
    
    if $DRY_RUN; then
        echo -e "${YELLOW}NOTA: Esto fue un dry-run, nada se ejecutó realmente${NC}"
    fi
    
    echo ""
    echo -e "${YELLOW}⚠️  IMPORTANTE: Se recomienda reiniciar el servidor${NC}"
    echo ""
    echo "Próximos pasos:"
    echo "1. Reiniciar el servidor: sudo reboot"
    echo "2. Verificar que SSH sigue funcionando"
    echo "3. Configurar WireGuard desde el servidor central (N150)"
    echo "4. Continuar con la instalación de k3s"
}

#===============================================================================
# MAIN
#===============================================================================
main() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║           ZCLOUD CLEANUP SCRIPT v1.2                       ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
    
    if [[ $EUID -ne 0 ]]; then
        log_error "Este script debe ejecutarse como root"
        exit 1
    fi
    
    detect_server
    confirm_cleanup
    
    cleanup_k3s
    cleanup_docker
    cleanup_podman
    cleanup_monitoring
    cleanup_nfs
    cleanup_firewall
    cleanup_network_interfaces
    cleanup_wireguard
    update_and_cleanup_system
    
    final_report
}

main "$@"