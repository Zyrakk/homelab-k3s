#!/bin/bash
#===============================================================================
# NVME NFS SETUP SCRIPT
# Exporta /mnt/nvme por NFS para el StorageClass nfs-nvme
#
# USO: sudo ./nvme-das-setup.sh
#===============================================================================

set -euo pipefail

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuracion
NVME_MOUNT="/mnt/nvme"
VPN_NETWORK="10.10.0.0/24"

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Este script debe ejecutarse como root"
    fi
}

check_nvme_mount() {
    if [[ ! -d "$NVME_MOUNT" ]]; then
        log_error "No existe el directorio $NVME_MOUNT"
    fi

    if ! mountpoint -q "$NVME_MOUNT"; then
        log_error "$NVME_MOUNT no esta montado. Monta el NVMe antes de continuar."
    fi
}

check_nfs_tools() {
    if ! command -v exportfs &>/dev/null; then
        log_error "No se encontro exportfs. Instala nfs-kernel-server antes de continuar."
    fi
}

backup_exports() {
    if [[ -f /etc/exports ]]; then
        cp /etc/exports "/etc/exports.backup.$(date +%Y%m%d%H%M%S)"
        log_ok "Backup de /etc/exports creado"
    else
        cat > /etc/exports <<EOF
# /etc/exports - NFS exports
# Generado: $(date)
EOF
        log_ok "/etc/exports creado"
    fi
}

configure_permissions() {
    log_info "Configurando permisos en $NVME_MOUNT..."
    chown nobody:nogroup "$NVME_MOUNT"
    chmod 777 "$NVME_MOUNT"
    log_ok "Permisos configurados"
}

configure_exports() {
    if grep -qE "^${NVME_MOUNT}[[:space:]]" /etc/exports; then
        log_info "Export NFS para $NVME_MOUNT ya existe, saltando..."
        return 0
    fi

    log_info "Agregando export NFS para $NVME_MOUNT..."
    {
        echo ""
        echo "# NVMe fast storage"
        echo "${NVME_MOUNT}    ${VPN_NETWORK}(rw,sync,no_subtree_check,no_root_squash)"
    } >> /etc/exports

    log_ok "Export NFS agregado"
}

apply_nfs() {
    log_info "Reiniciando NFS server..."
    systemctl enable nfs-kernel-server
    systemctl restart nfs-kernel-server
    exportfs -ra
    log_ok "NFS server actualizado"
}

verify_exports() {
    if exportfs -v | grep -q "$NVME_MOUNT"; then
        log_ok "Export activo para $NVME_MOUNT"
    else
        log_warn "No se detecto export activo para $NVME_MOUNT"
        exportfs -v
    fi
}

main() {
    echo ""
    echo -e "${CYAN}==============================================${NC}"
    echo -e "${CYAN}        NVME NFS SETUP (nfs-nvme)            ${NC}"
    echo -e "${CYAN}==============================================${NC}"
    echo ""

    check_root
    check_nvme_mount
    check_nfs_tools
    backup_exports
    configure_permissions
    configure_exports
    apply_nfs
    verify_exports

    echo ""
    log_ok "Configuracion NVMe NFS completada"
}

main "$@"
