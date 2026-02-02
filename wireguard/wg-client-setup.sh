#!/bin/bash
#===============================================================================
# WIREGUARD CLIENT SETUP
# Instala WireGuard y configura el cliente con el archivo de configuración
#
# USO: 
#   1. Copia este script al cliente
#   2. Copia el archivo .conf generado por wg-add-peer
#   3. Ejecuta: sudo ./wg-client-setup.sh <archivo.conf>
#
# O sin archivo (configuración manual):
#   sudo ./wg-client-setup.sh --manual
#===============================================================================

set -euo pipefail

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

WG_DIR="/etc/wireguard"
WG_INTERFACE="wg0"

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

#===============================================================================
# INSTALACIÓN
#===============================================================================
install_wireguard() {
    log_info "Instalando WireGuard..."
    
    if command -v apt-get &> /dev/null; then
        apt-get update
        apt-get install -y wireguard wireguard-tools
    elif command -v dnf &> /dev/null; then
        dnf install -y wireguard-tools
    elif command -v yum &> /dev/null; then
        yum install -y epel-release
        yum install -y wireguard-tools
    elif command -v pacman &> /dev/null; then
        pacman -S --noconfirm wireguard-tools
    else
        log_error "Gestor de paquetes no soportado. Instala wireguard-tools manualmente."
    fi
    
    log_ok "WireGuard instalado"
}

#===============================================================================
# CONFIGURACIÓN MANUAL
#===============================================================================
manual_setup() {
    echo ""
    log_info "Configuración manual de WireGuard"
    echo ""
    
    mkdir -p "${WG_DIR}"
    chmod 700 "${WG_DIR}"
    
    echo "Pega el contenido del archivo de configuración generado por wg-add-peer"
    echo "Termina con una línea vacía y presiona Ctrl+D:"
    echo ""
    
    cat > "${WG_DIR}/${WG_INTERFACE}.conf"
    
    chmod 600 "${WG_DIR}/${WG_INTERFACE}.conf"
    log_ok "Configuración guardada"
}

#===============================================================================
# CONFIGURACIÓN DESDE ARCHIVO
#===============================================================================
file_setup() {
    local conf_file="$1"
    
    if [[ ! -f "$conf_file" ]]; then
        log_error "Archivo no encontrado: $conf_file"
    fi
    
    mkdir -p "${WG_DIR}"
    chmod 700 "${WG_DIR}"
    
    cp "$conf_file" "${WG_DIR}/${WG_INTERFACE}.conf"
    chmod 600 "${WG_DIR}/${WG_INTERFACE}.conf"
    
    log_ok "Configuración copiada desde $conf_file"
}

#===============================================================================
# HABILITAR SERVICIO
#===============================================================================
enable_service() {
    log_info "Habilitando servicio WireGuard..."
    
    # Parar si ya existe
    systemctl stop wg-quick@${WG_INTERFACE} 2>/dev/null || true
    
    systemctl enable wg-quick@${WG_INTERFACE}
    systemctl start wg-quick@${WG_INTERFACE}
    
    sleep 2
    
    if wg show ${WG_INTERFACE} &>/dev/null; then
        log_ok "WireGuard activo"
    else
        log_error "Error al iniciar WireGuard. Revisa la configuración."
    fi
}

#===============================================================================
# VERIFICAR CONEXIÓN
#===============================================================================
verify_connection() {
    log_info "Verificando conexión con el servidor..."
    
    echo ""
    if ping -c 3 -W 2 10.10.0.1 &>/dev/null; then
        echo -e "${GREEN}✅ Conexión exitosa con el servidor (10.10.0.1)${NC}"
    else
        echo -e "${YELLOW}⚠️  No se pudo conectar con 10.10.0.1${NC}"
        echo ""
        echo "Posibles causas:"
        echo "  - El servidor WireGuard no está activo"
        echo "  - Firewall bloqueando el puerto UDP"
        echo "  - La IP pública del servidor es incorrecta"
        echo ""
        echo "Verifica con: wg show"
    fi
    
    return 0
}

#===============================================================================
# INFORME FINAL
#===============================================================================
final_report() {
    local MY_IP=$(grep "Address" "${WG_DIR}/${WG_INTERFACE}.conf" | awk '{print $3}' | cut -d'/' -f1)
    
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}✅ WIREGUARD CLIENTE CONFIGURADO${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "  Tu IP en la VPN: ${MY_IP}"
    echo "  Interfaz:        ${WG_INTERFACE}"
    echo "  Config:          ${WG_DIR}/${WG_INTERFACE}.conf"
    echo ""
    echo "Comandos útiles:"
    echo "  wg show                         Ver estado"
    echo "  sudo systemctl status wg-quick@wg0   Estado del servicio"
    echo "  sudo systemctl restart wg-quick@wg0  Reiniciar"
    echo "  ping 10.10.0.1                  Probar conexión al servidor"
    echo ""
}

#===============================================================================
# MAIN
#===============================================================================
main() {
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║          WIREGUARD CLIENT SETUP                            ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    check_root
    install_wireguard
    
    if [[ $# -eq 0 ]]; then
        echo "USO:"
        echo "  $0 <archivo.conf>    Instalar desde archivo de configuración"
        echo "  $0 --manual          Configuración manual (pegar contenido)"
        echo ""
        exit 1
    elif [[ "$1" == "--manual" ]]; then
        manual_setup
    else
        file_setup "$1"
    fi
    
    enable_service
    verify_connection
    final_report
}

main "$@"