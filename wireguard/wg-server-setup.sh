#!/bin/bash
#===============================================================================
# WIREGUARD SERVER SETUP
# Instala y configura WireGuard como servidor central para la red mesh
#
# USO: sudo ./wg-server-setup.sh [OPCIONES]
#   --subnet      Subred VPN (default: 10.10.0.0/24)
#   --server-ip   IP del servidor en la VPN (default: 10.10.0.1)
#   --port        Puerto UDP (default: 51820)
#   --interface   Nombre interfaz WG (default: wg0)
#===============================================================================

set -euo pipefail

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuración por defecto
WG_SUBNET="10.10.0.0/24"
WG_SERVER_IP="10.10.0.1"
WG_PORT="51820"
WG_INTERFACE="wg0"
WG_DIR="/etc/wireguard"

# Parse argumentos
while [[ $# -gt 0 ]]; do
    case $1 in
        --subnet) WG_SUBNET="$2"; shift 2 ;;
        --server-ip) WG_SERVER_IP="$2"; shift 2 ;;
        --port) WG_PORT="$2"; shift 2 ;;
        --interface) WG_INTERFACE="$2"; shift 2 ;;
        *) echo "Opción desconocida: $1"; exit 1 ;;
    esac
done

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
    if [[ -f "${WG_DIR}/${WG_INTERFACE}.conf" ]]; then
        echo ""
        log_warn "Ya existe una configuración WireGuard en ${WG_DIR}/${WG_INTERFACE}.conf"
        read -p "¿Sobrescribir? (y/N): " response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            log_info "Operación cancelada"
            exit 0
        fi
        # Parar interfaz existente
        wg-quick down "${WG_INTERFACE}" 2>/dev/null || true
    fi
}

#===============================================================================
# INSTALACIÓN
#===============================================================================
install_wireguard() {
    log_info "Instalando WireGuard..."
    
    if command -v apt-get &> /dev/null; then
        apt-get update
        apt-get install -y wireguard wireguard-tools qrencode
    elif command -v dnf &> /dev/null; then
        dnf install -y wireguard-tools qrencode
    elif command -v yum &> /dev/null; then
        yum install -y epel-release
        yum install -y wireguard-tools qrencode
    else
        log_error "Gestor de paquetes no soportado"
    fi
    
    log_ok "WireGuard instalado"
}

#===============================================================================
# CONFIGURACIÓN DEL SISTEMA
#===============================================================================
configure_system() {
    log_info "Configurando sistema..."
    
    # Habilitar IP forwarding
    if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi
    
    if ! grep -q "^net.ipv6.conf.all.forwarding=1" /etc/sysctl.conf; then
        echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
    fi
    
    # Aplicar cambios
    sysctl -p
    
    # Crear directorio WireGuard con permisos seguros
    mkdir -p "${WG_DIR}"
    chmod 700 "${WG_DIR}"
    
    log_ok "Sistema configurado"
}

#===============================================================================
# GENERAR CLAVES DEL SERVIDOR
#===============================================================================
generate_server_keys() {
    log_info "Generando claves del servidor..."
    
    cd "${WG_DIR}"
    
    # Generar clave privada
    wg genkey | tee server_private.key | wg pubkey > server_public.key
    
    # Permisos seguros
    chmod 600 server_private.key
    chmod 644 server_public.key
    
    SERVER_PRIVATE_KEY=$(cat server_private.key)
    SERVER_PUBLIC_KEY=$(cat server_public.key)
    
    log_ok "Claves generadas"
    echo -e "${CYAN}   Clave pública del servidor: ${SERVER_PUBLIC_KEY}${NC}"
}

#===============================================================================
# DETECTAR INTERFAZ DE RED PRINCIPAL
#===============================================================================
detect_main_interface() {
    # Detectar la interfaz que tiene la ruta por defecto
    MAIN_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
    
    if [[ -z "$MAIN_INTERFACE" ]]; then
        log_warn "No se pudo detectar la interfaz principal"
        read -p "Introduce el nombre de la interfaz de red (ej: eth0, enp0s3): " MAIN_INTERFACE
    fi
    
    log_info "Interfaz de red principal: ${MAIN_INTERFACE}"
}

#===============================================================================
# CREAR CONFIGURACIÓN DEL SERVIDOR
#===============================================================================
create_server_config() {
    log_info "Creando configuración del servidor..."
    
    SERVER_PRIVATE_KEY=$(cat "${WG_DIR}/server_private.key")
    
    cat > "${WG_DIR}/${WG_INTERFACE}.conf" << EOF
#===============================================================================
# WireGuard Server Configuration
# Servidor Central - zcloud infrastructure
# Generado: $(date)
#===============================================================================

[Interface]
# Clave privada del servidor (NUNCA compartir)
PrivateKey = ${SERVER_PRIVATE_KEY}

# Dirección IP del servidor en la VPN
Address = ${WG_SERVER_IP}/24

# Puerto de escucha UDP
ListenPort = ${WG_PORT}

# Guardar configuración automáticamente al añadir peers
SaveConfig = false

# PostUp/PostDown para NAT (permite a los peers salir a internet a través del servidor)
# Descomentar si quieres que los peers usen este servidor como gateway
#PostUp = iptables -t nat -A POSTROUTING -o ${MAIN_INTERFACE} -j MASQUERADE
#PostDown = iptables -t nat -D POSTROUTING -o ${MAIN_INTERFACE} -j MASQUERADE

#===============================================================================
# PEERS - Añadir con wg-add-peer.sh
#===============================================================================

EOF

    chmod 600 "${WG_DIR}/${WG_INTERFACE}.conf"
    
    log_ok "Configuración creada en ${WG_DIR}/${WG_INTERFACE}.conf"
}

#===============================================================================
# CREAR SCRIPT PARA AÑADIR PEERS
#===============================================================================
create_add_peer_script() {
    log_info "Creando script para añadir peers..."
    
    cat > "${WG_DIR}/wg-add-peer.sh" << 'SCRIPT_EOF'
#!/bin/bash
#===============================================================================
# WG-ADD-PEER - Añade un nuevo peer a WireGuard
# USO: sudo ./wg-add-peer.sh <nombre> <ip>
# Ejemplo: sudo ./wg-add-peer.sh raspberry 10.10.0.2
#          sudo ./wg-add-peer.sh oracle1 10.10.0.3
#===============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

WG_DIR="/etc/wireguard"
WG_INTERFACE="wg0"

# Leer configuración del servidor
WG_PORT=$(grep "ListenPort" "${WG_DIR}/${WG_INTERFACE}.conf" | awk '{print $3}')
SERVER_PUBLIC_KEY=$(cat "${WG_DIR}/server_public.key")

# Obtener IP pública del servidor
SERVER_PUBLIC_IP=$(curl -s ifconfig.me || curl -s icanhazip.com || echo "TU_IP_PUBLICA")

if [[ $# -lt 2 ]]; then
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              WG-ADD-PEER - Añadir nuevo peer               ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "USO: $0 <nombre_peer> <ip_peer>"
    echo ""
    echo "Ejemplos:"
    echo "  $0 raspberry 10.10.0.2"
    echo "  $0 oracle1 10.10.0.3"
    echo "  $0 oracle2 10.10.0.4"
    echo "  $0 laptop 10.10.0.10"
    echo ""
    echo "IPs sugeridas para tu infraestructura:"
    echo "  10.10.0.1  - Servidor central (N150) [YA CONFIGURADO]"
    echo "  10.10.0.2  - Raspberry Pi 5"
    echo "  10.10.0.3  - Oracle Cloud 1"
    echo "  10.10.0.4  - Oracle Cloud 2"
    echo "  10.10.0.10+ - Dispositivos personales"
    echo ""
    
    # Mostrar peers existentes
    echo -e "${YELLOW}Peers actuales:${NC}"
    grep -E "^# Peer:|AllowedIPs" "${WG_DIR}/${WG_INTERFACE}.conf" 2>/dev/null | paste - - | sed 's/# Peer: /  /' | sed 's/AllowedIPs = / → /' || echo "  (ninguno)"
    echo ""
    exit 1
fi

PEER_NAME="$1"
PEER_IP="$2"

# Validar IP
if ! [[ "$PEER_IP" =~ ^10\.10\.0\.[0-9]+$ ]]; then
    echo -e "${RED}[ERROR]${NC} IP inválida. Debe estar en el rango 10.10.0.x"
    exit 1
fi

# Verificar si la IP ya está en uso
if grep -q "AllowedIPs = ${PEER_IP}/32" "${WG_DIR}/${WG_INTERFACE}.conf" 2>/dev/null; then
    echo -e "${RED}[ERROR]${NC} La IP ${PEER_IP} ya está asignada a otro peer"
    exit 1
fi

echo ""
echo -e "${BLUE}[INFO]${NC} Generando configuración para peer: ${PEER_NAME} (${PEER_IP})"

# Crear directorio para peers
mkdir -p "${WG_DIR}/peers"

# Generar claves del peer
PEER_PRIVATE_KEY=$(wg genkey)
PEER_PUBLIC_KEY=$(echo "$PEER_PRIVATE_KEY" | wg pubkey)
PEER_PSK=$(wg genpsk)

echo -e "${GREEN}[OK]${NC} Claves generadas"

# Añadir peer a la configuración del servidor
cat >> "${WG_DIR}/${WG_INTERFACE}.conf" << EOF

# Peer: ${PEER_NAME}
# Añadido: $(date)
[Peer]
PublicKey = ${PEER_PUBLIC_KEY}
PresharedKey = ${PEER_PSK}
AllowedIPs = ${PEER_IP}/32
# PersistentKeepalive = 25
EOF

echo -e "${GREEN}[OK]${NC} Peer añadido a la configuración del servidor"

# Crear archivo de configuración para el cliente
PEER_CONF="${WG_DIR}/peers/${PEER_NAME}.conf"

cat > "$PEER_CONF" << EOF
#===============================================================================
# WireGuard Client Configuration
# Peer: ${PEER_NAME}
# Generado: $(date)
#===============================================================================

[Interface]
# Clave privada de este peer (NUNCA compartir)
PrivateKey = ${PEER_PRIVATE_KEY}

# Dirección IP en la VPN
Address = ${PEER_IP}/24

# DNS (opcional - descomentar si se necesita)
#DNS = 1.1.1.1, 8.8.8.8

[Peer]
# Servidor central (N150)
PublicKey = ${SERVER_PUBLIC_KEY}
PresharedKey = ${PEER_PSK}

# Endpoint del servidor (IP pública:puerto)
Endpoint = ${SERVER_PUBLIC_IP}:${WG_PORT}

# IPs accesibles a través del túnel
# Solo red VPN (mesh entre servidores):
AllowedIPs = 10.10.0.0/24

# Para usar el servidor como gateway de TODO el tráfico, usar:
#AllowedIPs = 0.0.0.0/0, ::/0

# Mantener conexión activa (importante para peers detrás de NAT)
PersistentKeepalive = 25
EOF

chmod 600 "$PEER_CONF"

# Recargar WireGuard si está activo
if wg show "${WG_INTERFACE}" &>/dev/null; then
    wg syncconf "${WG_INTERFACE}" <(wg-quick strip "${WG_INTERFACE}")
    echo -e "${GREEN}[OK]${NC} Configuración recargada en caliente"
fi

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✅ PEER CONFIGURADO EXITOSAMENTE${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "Archivo de configuración: ${CYAN}${PEER_CONF}${NC}"
echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}INSTRUCCIONES PARA EL CLIENTE (${PEER_NAME}):${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "1. Copia este archivo al cliente:"
echo -e "   ${CYAN}scp ${PEER_CONF} ${PEER_NAME}:/etc/wireguard/wg0.conf${NC}"
echo ""
echo "2. O copia el contenido manualmente. Ejecuta en el cliente:"
echo -e "   ${CYAN}sudo nano /etc/wireguard/wg0.conf${NC}"
echo ""
echo "3. Contenido del archivo:"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
cat "$PEER_CONF"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "4. En el cliente, activa WireGuard:"
echo -e "   ${CYAN}sudo chmod 600 /etc/wireguard/wg0.conf${NC}"
echo -e "   ${CYAN}sudo systemctl enable wg-quick@wg0${NC}"
echo -e "   ${CYAN}sudo systemctl start wg-quick@wg0${NC}"
echo ""
echo "5. Verificar conexión desde el cliente:"
echo -e "   ${CYAN}ping 10.10.0.1${NC}"
echo ""

# Mostrar QR si es posible (útil para móviles)
if command -v qrencode &>/dev/null; then
    echo -e "${YELLOW}QR Code (para apps móviles WireGuard):${NC}"
    qrencode -t ansiutf8 -m 2 -s 1 < "$PEER_CONF"
fi
SCRIPT_EOF

    chmod +x "${WG_DIR}/wg-add-peer.sh"
    
    # Crear enlace simbólico en /usr/local/bin
    ln -sf "${WG_DIR}/wg-add-peer.sh" /usr/local/bin/wg-add-peer
    
    log_ok "Script wg-add-peer creado"
}

#===============================================================================
# CREAR SCRIPT PARA LISTAR PEERS
#===============================================================================
create_list_peers_script() {
    cat > "${WG_DIR}/wg-list-peers.sh" << 'SCRIPT_EOF'
#!/bin/bash
#===============================================================================
# WG-LIST-PEERS - Lista todos los peers configurados
#===============================================================================

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo ""
echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║              WIREGUARD PEERS STATUS                        ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Mostrar estado de WireGuard
if wg show wg0 &>/dev/null; then
    echo -e "${GREEN}[●] WireGuard ACTIVO${NC}"
    echo ""
    wg show wg0
else
    echo -e "${RED}[○] WireGuard INACTIVO${NC}"
    echo ""
    echo "Para activar: sudo systemctl start wg-quick@wg0"
fi

echo ""
echo -e "${YELLOW}Archivos de configuración de peers:${NC}"
ls -la /etc/wireguard/peers/ 2>/dev/null || echo "  No hay peers configurados"
echo ""
SCRIPT_EOF

    chmod +x "${WG_DIR}/wg-list-peers.sh"
    ln -sf "${WG_DIR}/wg-list-peers.sh" /usr/local/bin/wg-list-peers
}

#===============================================================================
# CREAR SCRIPT PARA ELIMINAR PEERS
#===============================================================================
create_remove_peer_script() {
    cat > "${WG_DIR}/wg-remove-peer.sh" << 'SCRIPT_EOF'
#!/bin/bash
#===============================================================================
# WG-REMOVE-PEER - Elimina un peer de WireGuard
# USO: sudo ./wg-remove-peer.sh <nombre>
#===============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

WG_DIR="/etc/wireguard"
WG_INTERFACE="wg0"

if [[ $# -lt 1 ]]; then
    echo "USO: $0 <nombre_peer>"
    echo ""
    echo "Peers existentes:"
    ls "${WG_DIR}/peers/" 2>/dev/null | sed 's/.conf$//' | sed 's/^/  /' || echo "  (ninguno)"
    exit 1
fi

PEER_NAME="$1"
PEER_CONF="${WG_DIR}/peers/${PEER_NAME}.conf"

if [[ ! -f "$PEER_CONF" ]]; then
    echo -e "${RED}[ERROR]${NC} No existe el peer: ${PEER_NAME}"
    exit 1
fi

# Obtener clave pública del peer
PEER_PUBLIC_KEY=$(grep "PrivateKey" "$PEER_CONF" | awk '{print $3}' | wg pubkey)

echo -e "${YELLOW}[WARN]${NC} Vas a eliminar el peer: ${PEER_NAME}"
read -p "¿Continuar? (y/N): " response

if [[ ! "$response" =~ ^[Yy]$ ]]; then
    echo "Operación cancelada"
    exit 0
fi

# Eliminar de la configuración del servidor
# Buscar y eliminar el bloque del peer
sed -i "/# Peer: ${PEER_NAME}/,/^$/d" "${WG_DIR}/${WG_INTERFACE}.conf"

# Eliminar archivo de configuración del peer
rm -f "$PEER_CONF"

# Recargar WireGuard
if wg show "${WG_INTERFACE}" &>/dev/null; then
    wg syncconf "${WG_INTERFACE}" <(wg-quick strip "${WG_INTERFACE}")
fi

echo -e "${GREEN}[OK]${NC} Peer ${PEER_NAME} eliminado"
SCRIPT_EOF

    chmod +x "${WG_DIR}/wg-remove-peer.sh"
    ln -sf "${WG_DIR}/wg-remove-peer.sh" /usr/local/bin/wg-remove-peer
}

#===============================================================================
# HABILITAR Y ARRANCAR SERVICIO
#===============================================================================
enable_service() {
    log_info "Habilitando servicio WireGuard..."
    
    systemctl enable wg-quick@${WG_INTERFACE}
    systemctl start wg-quick@${WG_INTERFACE}
    
    # Verificar estado
    if wg show ${WG_INTERFACE} &>/dev/null; then
        log_ok "WireGuard activo y funcionando"
    else
        log_error "Error al iniciar WireGuard"
    fi
}

#===============================================================================
# INFORME FINAL
#===============================================================================
final_report() {
    SERVER_PUBLIC_KEY=$(cat "${WG_DIR}/server_public.key")
    SERVER_PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || echo "NO_DETECTADA")
    
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}✅ WIREGUARD SERVIDOR CONFIGURADO EXITOSAMENTE${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "Configuración:"
    echo "  Interfaz:        ${WG_INTERFACE}"
    echo "  IP en VPN:       ${WG_SERVER_IP}"
    echo "  Puerto UDP:      ${WG_PORT}"
    echo "  Subred VPN:      ${WG_SUBNET}"
    echo "  IP pública:      ${SERVER_PUBLIC_IP}"
    echo ""
    echo "Claves:"
    echo "  Pública:         ${SERVER_PUBLIC_KEY}"
    echo "  Privada:         ${WG_DIR}/server_private.key"
    echo ""
    echo "Archivos:"
    echo "  Config servidor: ${WG_DIR}/${WG_INTERFACE}.conf"
    echo "  Configs peers:   ${WG_DIR}/peers/"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}COMANDOS DISPONIBLES:${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  wg-add-peer <nombre> <ip>    Añadir nuevo peer"
    echo "  wg-list-peers                Listar peers y estado"
    echo "  wg-remove-peer <nombre>      Eliminar peer"
    echo "  wg show                      Estado de WireGuard"
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}PRÓXIMOS PASOS - Añadir tus servidores:${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  sudo wg-add-peer raspberry 10.10.0.2"
    echo "  sudo wg-add-peer oracle1 10.10.0.3"
    echo "  sudo wg-add-peer oracle2 10.10.0.4"
    echo ""
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}⚠️  IMPORTANTE - FIREWALL:${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  Asegúrate de abrir el puerto UDP ${WG_PORT} en tu firewall/router"
    echo ""
    echo "  UFW:     sudo ufw allow ${WG_PORT}/udp"
    echo "  Router:  Port forward UDP ${WG_PORT} → ${SERVER_PUBLIC_IP}:${WG_PORT}"
    echo ""
}

#===============================================================================
# MAIN
#===============================================================================
main() {
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║          WIREGUARD SERVER SETUP - zcloud                   ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    check_root
    check_existing
    install_wireguard
    configure_system
    generate_server_keys
    detect_main_interface
    create_server_config
    create_add_peer_script
    create_list_peers_script
    create_remove_peer_script
    
    # Crear directorio para configs de peers
    mkdir -p "${WG_DIR}/peers"
    chmod 700 "${WG_DIR}/peers"
    
    enable_service
    final_report
}

main "$@"