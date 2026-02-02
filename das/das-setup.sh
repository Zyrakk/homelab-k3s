#!/bin/bash
#===============================================================================
# DAS SETUP SCRIPT
# Configura el DAS con nueva estructura LVM, NFS exports y NVMe local
#
# USO: sudo ./das-setup.sh
#
# ESTRUCTURA CREADA:
#   lv_oracle1  (5TB)   → /mnt/nfs/oracle1  → Export NFS para Oracle 1
#   lv_oracle2  (5TB)   → /mnt/nfs/oracle2  → Export NFS para Oracle 2
#   lv_local    (4TB)   → /mnt/local        → Almacenamiento local Pi
#   lv_shared   (4TB)   → /mnt/nfs/shared   → Export NFS compartido (transferencias)
#   [libre]     (~3.8TB)→ Reserva para expansión futura
#
#   NVMe (477GB) → /mnt/nvme → Almacenamiento rápido local
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
VG_NAME="vg_das"
NVME_DEVICE="/dev/nvme0n1"
NVME_PARTITION="${NVME_DEVICE}p1"

# Estructura de volúmenes: nombre|tamaño|punto_montaje|es_nfs_export
declare -A VOLUMES=(
    ["lv_oracle1"]="5T|/mnt/nfs/oracle1|yes"
    ["lv_oracle2"]="5T|/mnt/nfs/oracle2|yes"
    ["lv_local"]="4T|/mnt/local|no"
    ["lv_shared"]="4T|/mnt/nfs/shared|yes"
)

# Red VPN para NFS exports
VPN_NETWORK="10.10.0.0/24"

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

check_vg_exists() {
    if ! vgs "$VG_NAME" &>/dev/null; then
        log_error "Volume Group '$VG_NAME' no existe. ¿Ejecutaste das-cleanup.sh?"
    fi
    
    VG_FREE=$(vgs --noheadings --units g -o vg_free "$VG_NAME" | tr -d ' ' | sed 's/g$//')
    VG_FREE_TB=$(echo "scale=2; $VG_FREE / 1024" | bc)
    
    log_info "Volume Group '$VG_NAME' encontrado con ${VG_FREE_TB}TB libres"
}

check_no_lvs() {
    LV_COUNT=$(lvs --noheadings "$VG_NAME" 2>/dev/null | wc -l)
    if [[ $LV_COUNT -gt 0 ]]; then
        log_warn "Existen $LV_COUNT Logical Volumes en $VG_NAME"
        echo ""
        lvs "$VG_NAME"
        echo ""
        read -p "¿Continuar y crear los nuevos LVs? Los existentes se mantendrán (y/N): " response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            log_info "Operación cancelada. Ejecuta das-cleanup.sh primero si quieres empezar de cero."
            exit 0
        fi
    fi
}

show_plan() {
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                    PLAN DE CONFIGURACIÓN                        ${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}Volúmenes LVM a crear en ${VG_NAME}:${NC}"
    echo ""
    printf "  %-15s %-8s %-25s %-10s\n" "VOLUMEN" "TAMAÑO" "PUNTO MONTAJE" "NFS EXPORT"
    printf "  %-15s %-8s %-25s %-10s\n" "───────────────" "────────" "─────────────────────────" "──────────"
    
    for lv_name in "${!VOLUMES[@]}"; do
        IFS='|' read -r size mount_point is_nfs <<< "${VOLUMES[$lv_name]}"
        printf "  %-15s %-8s %-25s %-10s\n" "$lv_name" "$size" "$mount_point" "$is_nfs"
    done | sort
    
    echo ""
    echo -e "${YELLOW}NVMe (almacenamiento rápido):${NC}"
    echo "  Dispositivo: ${NVME_PARTITION}"
    echo "  Montaje:     /mnt/nvme"
    echo "  Uso:         Almacenamiento local de alta velocidad"
    echo ""
    echo -e "${YELLOW}NFS Exports:${NC}"
    echo "  Red permitida: ${VPN_NETWORK} (red WireGuard)"
    echo ""
    
    read -p "¿Continuar con la configuración? (y/N): " response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        log_info "Operación cancelada"
        exit 0
    fi
}

#===============================================================================
# INSTALAR DEPENDENCIAS
#===============================================================================
install_dependencies() {
    log_info "Instalando dependencias..."
    
    apt-get update
    apt-get install -y nfs-kernel-server nfs-common lvm2 parted
    
    log_ok "Dependencias instaladas"
}

#===============================================================================
# CREAR LOGICAL VOLUMES
#===============================================================================
create_logical_volumes() {
    log_info "Creando Logical Volumes..."
    
    for lv_name in "${!VOLUMES[@]}"; do
        IFS='|' read -r size mount_point is_nfs <<< "${VOLUMES[$lv_name]}"
        
        # Verificar si ya existe
        if lvs "${VG_NAME}/${lv_name}" &>/dev/null; then
            log_warn "LV $lv_name ya existe, saltando..."
            continue
        fi
        
        log_info "Creando $lv_name (${size})..."
        # -y para auto-confirmar si detecta firmas previas
        # -W y para auto-confirmar wipe
        lvcreate -y -W y -L "$size" -n "$lv_name" "$VG_NAME"
        log_ok "Creado: $lv_name"
    done
    
    log_ok "Logical Volumes creados"
}

#===============================================================================
# FORMATEAR VOLÚMENES
#===============================================================================
format_volumes() {
    log_info "Formateando volúmenes con ext4..."
    
    for lv_name in "${!VOLUMES[@]}"; do
        LV_PATH="/dev/${VG_NAME}/${lv_name}"
        
        # Verificar si ya tiene filesystem
        if blkid "$LV_PATH" &>/dev/null; then
            log_warn "$lv_name ya tiene filesystem, saltando formateo..."
            continue
        fi
        
        log_info "Formateando $lv_name..."
        mkfs.ext4 -F -L "$lv_name" "$LV_PATH"
        log_ok "Formateado: $lv_name"
    done
    
    log_ok "Volúmenes formateados"
}

#===============================================================================
# CONFIGURAR NVME
#===============================================================================
setup_nvme() {
    log_info "Configurando NVMe..."
    
    # Verificar que existe el dispositivo
    if [[ ! -b "$NVME_PARTITION" ]]; then
        log_warn "Partición NVMe $NVME_PARTITION no encontrada"
        
        if [[ -b "$NVME_DEVICE" ]]; then
            log_info "Dispositivo NVMe encontrado, creando partición..."
            
            # Crear tabla de particiones GPT y una partición que ocupe todo
            parted -s "$NVME_DEVICE" mklabel gpt
            parted -s "$NVME_DEVICE" mkpart primary ext4 0% 100%
            
            # Esperar a que aparezca la partición
            sleep 2
            partprobe "$NVME_DEVICE"
            sleep 1
            
            if [[ ! -b "$NVME_PARTITION" ]]; then
                log_warn "No se pudo crear la partición NVMe, continuando sin NVMe..."
                return 0
            fi
        else
            log_warn "No se encontró dispositivo NVMe, saltando..."
            return 0
        fi
    fi
    
    # Verificar si ya tiene filesystem
    if ! blkid "$NVME_PARTITION" &>/dev/null; then
        log_info "Formateando NVMe..."
        mkfs.ext4 -F -L nvme_fast "$NVME_PARTITION"
    else
        log_info "NVMe ya tiene filesystem"
    fi
    
    # Crear punto de montaje
    mkdir -p /mnt/nvme
    
    log_ok "NVMe configurado"
}

#===============================================================================
# CREAR PUNTOS DE MONTAJE
#===============================================================================
create_mount_points() {
    log_info "Creando puntos de montaje..."
    
    # Crear estructura de directorios
    mkdir -p /mnt/nfs/oracle1
    mkdir -p /mnt/nfs/oracle2
    mkdir -p /mnt/nfs/shared
    mkdir -p /mnt/local
    mkdir -p /mnt/nvme
    
    # Permisos
    chmod 755 /mnt/nfs
    chmod 755 /mnt/local
    chmod 755 /mnt/nvme
    
    log_ok "Puntos de montaje creados"
}

#===============================================================================
# MONTAR VOLÚMENES
#===============================================================================
mount_volumes() {
    log_info "Montando volúmenes..."
    
    for lv_name in "${!VOLUMES[@]}"; do
        IFS='|' read -r size mount_point is_nfs <<< "${VOLUMES[$lv_name]}"
        LV_PATH="/dev/${VG_NAME}/${lv_name}"
        
        # Verificar si ya está montado
        if mountpoint -q "$mount_point" 2>/dev/null; then
            log_info "$mount_point ya está montado"
            continue
        fi
        
        log_info "Montando $lv_name en $mount_point..."
        mount "$LV_PATH" "$mount_point"
        log_ok "Montado: $mount_point"
    done
    
    # Montar NVMe
    if [[ -b "$NVME_PARTITION" ]] && ! mountpoint -q /mnt/nvme 2>/dev/null; then
        log_info "Montando NVMe..."
        mount "$NVME_PARTITION" /mnt/nvme
        log_ok "Montado: /mnt/nvme"
    fi
    
    log_ok "Volúmenes montados"
}

#===============================================================================
# CONFIGURAR FSTAB
#===============================================================================
configure_fstab() {
    log_info "Configurando /etc/fstab..."
    
    # Backup
    cp /etc/fstab /etc/fstab.backup.$(date +%Y%m%d%H%M%S)
    
    # Añadir entradas para LVs
    for lv_name in "${!VOLUMES[@]}"; do
        IFS='|' read -r size mount_point is_nfs <<< "${VOLUMES[$lv_name]}"
        LV_PATH="/dev/${VG_NAME}/${lv_name}"
        
        # Verificar si ya existe en fstab
        if grep -q "$LV_PATH" /etc/fstab; then
            log_info "Entrada para $lv_name ya existe en fstab"
            continue
        fi
        
        echo "$LV_PATH  $mount_point  ext4  defaults,nofail  0  2" >> /etc/fstab
        log_ok "Añadido a fstab: $lv_name"
    done
    
    # Añadir entrada para NVMe
    if [[ -b "$NVME_PARTITION" ]] && ! grep -q "$NVME_PARTITION" /etc/fstab; then
        NVME_UUID=$(blkid -s UUID -o value "$NVME_PARTITION")
        echo "UUID=$NVME_UUID  /mnt/nvme  ext4  defaults,nofail  0  2" >> /etc/fstab
        log_ok "Añadido a fstab: NVMe"
    fi
    
    # Verificar fstab
    if mount -a 2>/dev/null; then
        log_ok "fstab verificado correctamente"
    else
        log_warn "Posible error en fstab, revisar manualmente"
    fi
}

#===============================================================================
# CONFIGURAR NFS
#===============================================================================
configure_nfs() {
    log_info "Configurando NFS server..."
    
    # Backup exports
    [[ -f /etc/exports ]] && cp /etc/exports /etc/exports.backup.$(date +%Y%m%d%H%M%S)
    
    # Crear nuevo /etc/exports
    cat > /etc/exports << EOF
# /etc/exports - NFS exports para zcloud infrastructure
# Generado: $(date)
# Red permitida: ${VPN_NETWORK} (WireGuard VPN)

# Oracle 1 - Almacenamiento dedicado (5TB)
/mnt/nfs/oracle1    ${VPN_NETWORK}(rw,sync,no_subtree_check,no_root_squash)

# Oracle 2 - Almacenamiento dedicado (5TB)
/mnt/nfs/oracle2    ${VPN_NETWORK}(rw,sync,no_subtree_check,no_root_squash)

# Shared - Almacenamiento compartido para transferencias (4TB)
/mnt/nfs/shared     ${VPN_NETWORK}(rw,sync,no_subtree_check,no_root_squash)

EOF

    log_ok "Exports configurados"
    
    # Establecer permisos en directorios NFS
    log_info "Configurando permisos..."
    for dir in /mnt/nfs/oracle1 /mnt/nfs/oracle2 /mnt/nfs/shared; do
        chown nobody:nogroup "$dir"
        chmod 777 "$dir"
    done
    
    # Habilitar y arrancar NFS
    log_info "Habilitando NFS server..."
    systemctl enable nfs-kernel-server
    systemctl restart nfs-kernel-server
    
    # Exportar filesystems
    exportfs -ra
    
    log_ok "NFS server configurado y activo"
}

#===============================================================================
# CONFIGURAR PERMISOS LOCALES
#===============================================================================
configure_local_permissions() {
    log_info "Configurando permisos locales..."
    
    # /mnt/local para uso de la Pi
    chown root:root /mnt/local
    chmod 755 /mnt/local
    
    # /mnt/nvme para uso de alta velocidad
    if mountpoint -q /mnt/nvme 2>/dev/null; then
        chown root:root /mnt/nvme
        chmod 755 /mnt/nvme
        
        # Crear subdirectorios útiles
        mkdir -p /mnt/nvme/k3s-local
        mkdir -p /mnt/nvme/cache
        mkdir -p /mnt/nvme/tmp
    fi
    
    log_ok "Permisos configurados"
}

#===============================================================================
# CREAR SCRIPT DE ESTADO
#===============================================================================
create_status_script() {
    log_info "Creando script de estado..."
    
    cat > /usr/local/bin/das-status << 'EOF'
#!/bin/bash
# DAS Status - Muestra estado del almacenamiento

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo ""
echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║                    DAS STATUS                              ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${YELLOW}Logical Volumes:${NC}"
sudo lvs vg_das --units g -o lv_name,lv_size 2>/dev/null || echo "  Error al leer LVs (¿ejecutar con sudo?)"
echo ""

echo -e "${YELLOW}Espacio libre en VG (para expansión):${NC}"
sudo vgs vg_das --units t -o vg_free --noheadings 2>/dev/null | xargs echo " " || echo "  N/A"
echo ""

echo -e "${YELLOW}Uso de disco:${NC}"
df -h /mnt/nfs/* /mnt/local /mnt/nvme 2>/dev/null | grep -v "^Filesystem" | while read line; do
    echo "  $line"
done
echo ""

echo -e "${YELLOW}NFS Exports:${NC}"
cat /etc/exports 2>/dev/null | grep -v "^#" | grep -v "^$" | while read line; do
    echo "  $line"
done || echo "  Ninguno"
echo ""

echo -e "${YELLOW}NFS Server Status:${NC}"
if systemctl is-active --quiet nfs-kernel-server; then
    echo -e "  ${GREEN}● Activo${NC}"
else
    echo -e "  ${RED}○ Inactivo${NC}"
fi
echo ""

echo -e "${YELLOW}Clientes NFS conectados:${NC}"
CLIENTS=$(ss -tn state established '( dport = :2049 or sport = :2049 )' 2>/dev/null | tail -n +2)
if [[ -n "$CLIENTS" ]]; then
    echo "$CLIENTS" | while read line; do
        echo "  $line"
    done
else
    echo "  (ninguno)"
fi
echo ""
EOF

    chmod +x /usr/local/bin/das-status
    log_ok "Script das-status creado"
}

#===============================================================================
# INFORME FINAL
#===============================================================================
final_report() {
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}✅ DAS CONFIGURADO EXITOSAMENTE${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    echo -e "${YELLOW}Volúmenes creados:${NC}"
    lvs "$VG_NAME" --units g -o lv_name,lv_size
    echo ""
    
    echo -e "${YELLOW}Espacio libre en VG (para expansión futura):${NC}"
    vgs "$VG_NAME" --units t -o vg_free
    echo ""
    
    echo -e "${YELLOW}Puntos de montaje:${NC}"
    df -h /mnt/nfs/* /mnt/local /mnt/nvme 2>/dev/null
    echo ""
    
    echo -e "${YELLOW}NFS Exports activos:${NC}"
    exportfs -v
    echo ""
    
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}COMANDOS ÚTILES:${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  das-status              Ver estado del DAS"
    echo "  exportfs -v             Ver exports NFS"
    echo ""
    echo "  # Expandir un volumen (ejemplo +1TB a oracle1):"
    echo "  lvextend -L +1T vg_das/lv_oracle1 && resize2fs /dev/vg_das/lv_oracle1"
    echo ""
    
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}PRÓXIMOS PASOS - MONTAR EN ORACLES:${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "En Oracle 1 (10.10.0.3):"
    echo "  sudo mkdir -p /mnt/das"
    echo "  sudo mount -t nfs 10.10.0.2:/mnt/nfs/oracle1 /mnt/das"
    echo "  # Añadir a /etc/fstab para montaje permanente:"
    echo "  echo '10.10.0.2:/mnt/nfs/oracle1 /mnt/das nfs defaults,_netdev 0 0' | sudo tee -a /etc/fstab"
    echo ""
    echo "En Oracle 2 (10.10.0.4):"
    echo "  sudo mkdir -p /mnt/das"
    echo "  sudo mount -t nfs 10.10.0.2:/mnt/nfs/oracle2 /mnt/das"
    echo "  # Añadir a /etc/fstab para montaje permanente:"
    echo "  echo '10.10.0.2:/mnt/nfs/oracle2 /mnt/das nfs defaults,_netdev 0 0' | sudo tee -a /etc/fstab"
    echo ""
    echo "Para acceder al volumen compartido desde cualquier nodo:"
    echo "  sudo mount -t nfs 10.10.0.2:/mnt/nfs/shared /mnt/shared"
    echo ""
}

#===============================================================================
# MAIN
#===============================================================================
main() {
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              DAS SETUP SCRIPT                              ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    check_root
    check_vg_exists
    check_no_lvs
    show_plan
    
    install_dependencies
    create_logical_volumes
    format_volumes
    setup_nvme
    create_mount_points
    mount_volumes
    configure_fstab
    configure_nfs
    configure_local_permissions
    create_status_script
    
    final_report
}

main "$@"