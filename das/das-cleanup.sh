#!/bin/bash
#===============================================================================
# DAS CLEANUP SCRIPT (Universal)
# Limpia completamente el DAS: desmonta, elimina TODOS los LVs y prepara para
# nueva configuración. Funciona con cualquier estructura existente.
#
# USO: sudo ./das-cleanup.sh [--force]
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

FORCE=false
[[ "${1:-}" == "--force" ]] && FORCE=true

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

show_current_state() {
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                    ESTADO ACTUAL DEL DAS                        ${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Verificar si existe el VG
    if ! vgs "$VG_NAME" &>/dev/null; then
        log_error "Volume Group '$VG_NAME' no encontrado"
    fi
    
    echo -e "${YELLOW}Volume Group:${NC}"
    vgs "$VG_NAME" 2>/dev/null || echo "  No existe $VG_NAME"
    echo ""
    
    echo -e "${YELLOW}Logical Volumes en $VG_NAME:${NC}"
    if lvs "$VG_NAME" --noheadings 2>/dev/null | grep -q .; then
        lvs "$VG_NAME" 2>/dev/null
    else
        echo "  Ninguno"
    fi
    echo ""
    
    echo -e "${YELLOW}Puntos de montaje de $VG_NAME:${NC}"
    if mount | grep -q "$VG_NAME"; then
        mount | grep "$VG_NAME"
    else
        echo "  Ninguno montado"
    fi
    echo ""
    
    echo -e "${YELLOW}Entradas en /etc/fstab relacionadas:${NC}"
    if grep -qE "$VG_NAME|/mnt/nfs|/mnt/local|/mnt/das|/mnt/chat" /etc/fstab 2>/dev/null; then
        grep -E "$VG_NAME|/mnt/nfs|/mnt/local|/mnt/das|/mnt/chat" /etc/fstab
    else
        echo "  Ninguna encontrada"
    fi
    echo ""
    
    echo -e "${YELLOW}Exports NFS actuales:${NC}"
    if [[ -f /etc/exports ]] && grep -vE "^#|^$" /etc/exports | grep -q .; then
        grep -vE "^#|^$" /etc/exports
    else
        echo "  Ninguno"
    fi
    echo ""
}

confirm_cleanup() {
    if $FORCE; then
        return 0
    fi
    
    echo -e "${RED}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${RED}⚠️  ADVERTENCIA: ESTO ELIMINARÁ TODOS LOS DATOS DEL DAS ⚠️${NC}"
    echo -e "${RED}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "Se eliminarán:"
    echo "  - Todos los Logical Volumes (lv_das, lv_logs, etc.)"
    echo "  - Todos los datos contenidos en ellos"
    echo "  - Configuración NFS exports"
    echo "  - Entradas de /etc/fstab relacionadas"
    echo ""
    echo "El Volume Group (vg_das) se mantendrá para reutilizarlo."
    echo ""
    read -p "Escribe 'ELIMINAR TODO' para confirmar: " response
    
    if [[ "$response" != "ELIMINAR TODO" ]]; then
        log_info "Operación cancelada"
        exit 0
    fi
}

#===============================================================================
# PARAR SERVICIOS
#===============================================================================
stop_services() {
    log_info "Parando servicios que puedan usar el DAS..."
    
    # Parar NFS
    if systemctl is-active --quiet nfs-server 2>/dev/null; then
        systemctl stop nfs-server
        log_ok "NFS server parado"
    fi
    
    # Parar NFS kernel server (Debian/Ubuntu)
    if systemctl is-active --quiet nfs-kernel-server 2>/dev/null; then
        systemctl stop nfs-kernel-server
        log_ok "NFS kernel server parado"
    fi
}

#===============================================================================
# LIMPIAR NFS
#===============================================================================
cleanup_nfs() {
    log_info "Limpiando configuración NFS..."
    
    # Desexportar todo
    exportfs -ua 2>/dev/null || true
    
    # Limpiar /etc/exports (mantener comentarios de cabecera)
    if [[ -f /etc/exports ]]; then
        cp /etc/exports /etc/exports.backup.$(date +%Y%m%d%H%M%S)
        cat > /etc/exports << 'EOF'
# /etc/exports: the access control list for filesystems which may be exported
#               to NFS clients.  See exports(5).
#
# Example for NFSv2 and NFSv3:
# /srv/homes       hostname1(rw,sync,no_subtree_check) hostname2(ro,sync,no_subtree_check)
#
# Example for NFSv4:
# /srv/nfs4        guesthost(rw,sync,fsid=0,crossmnt,no_subtree_check)
# /srv/nfs4/homes  guesthost(rw,sync,no_subtree_check)
#

EOF
        log_ok "NFS exports limpiados (backup creado)"
    fi
}

#===============================================================================
# DESMONTAR VOLÚMENES (Universal)
#===============================================================================
unmount_volumes() {
    log_info "Desmontando todos los volúmenes de $VG_NAME..."
    
    # Obtener todos los puntos de montaje del VG
    MOUNTED=$(mount | grep "/dev/mapper/${VG_NAME}" | awk '{print $3}' || true)
    
    if [[ -z "$MOUNTED" ]]; then
        log_info "No hay volúmenes montados de $VG_NAME"
        return 0
    fi
    
    for mp in $MOUNTED; do
        log_info "Desmontando $mp..."
        
        # Matar procesos que usen el mount
        fuser -km "$mp" 2>/dev/null || true
        sleep 1
        
        if umount -f "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null; then
            log_ok "Desmontado: $mp"
        else
            log_warn "No se pudo desmontar: $mp"
        fi
    done
    
    # Intentar desmontar por dispositivo directamente
    for lv_path in /dev/${VG_NAME}/*; do
        if [[ -e "$lv_path" ]]; then
            mp=$(findmnt -n -o TARGET "$lv_path" 2>/dev/null || true)
            if [[ -n "$mp" ]]; then
                log_info "Desmontando $lv_path de $mp..."
                fuser -km "$mp" 2>/dev/null || true
                umount -f "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true
            fi
        fi
    done
    
    log_ok "Volúmenes desmontados"
}

#===============================================================================
# LIMPIAR FSTAB (Universal)
#===============================================================================
cleanup_fstab() {
    log_info "Limpiando /etc/fstab..."
    
    # Verificar si hay entradas que limpiar
    if ! grep -qE "$VG_NAME|/mnt/nfs|/mnt/local|/mnt/das|/mnt/chat" /etc/fstab 2>/dev/null; then
        log_info "No hay entradas relacionadas en fstab"
        return 0
    fi
    
    cp /etc/fstab /etc/fstab.backup.$(date +%Y%m%d%H%M%S)
    
    # Eliminar todas las entradas relacionadas con el VG y nuestros puntos de montaje
    grep -vE "$VG_NAME|/mnt/nfs|/mnt/local|/mnt/das|/mnt/chat" /etc/fstab > /etc/fstab.tmp || true
    mv /etc/fstab.tmp /etc/fstab
    
    log_ok "fstab limpiado (backup creado)"
}

#===============================================================================
# ELIMINAR LOGICAL VOLUMES (Universal)
#===============================================================================
remove_logical_volumes() {
    log_info "Eliminando todos los Logical Volumes de $VG_NAME..."
    
    # Obtener lista de LVs en el VG
    LVS=$(lvs --noheadings -o lv_name "$VG_NAME" 2>/dev/null | tr -d ' ' || true)
    
    if [[ -z "$LVS" ]]; then
        log_info "No hay Logical Volumes que eliminar"
        return 0
    fi
    
    for lv in $LVS; do
        log_info "Eliminando LV: $lv"
        
        # Desactivar primero
        lvchange -an "${VG_NAME}/$lv" 2>/dev/null || true
        
        # Eliminar con -y para auto-confirmar
        if lvremove -y -f "${VG_NAME}/$lv" 2>/dev/null; then
            log_ok "Eliminado: $lv"
        else
            log_warn "No se pudo eliminar: $lv"
        fi
    done
    
    log_ok "Logical Volumes eliminados"
}

#===============================================================================
# LIMPIAR DIRECTORIOS (Universal)
#===============================================================================
cleanup_directories() {
    log_info "Limpiando directorios de montaje..."
    
    # Directorios que podrían existir
    DIRS_TO_CHECK=(
        "/mnt/nfs"
        "/mnt/local"
        "/mnt/das"
        "/mnt/chat-ai"
    )
    
    for dir in "${DIRS_TO_CHECK[@]}"; do
        if [[ -d "$dir" ]]; then
            # Verificar que no esté montado
            if ! mountpoint -q "$dir" 2>/dev/null && ! mount | grep -q " $dir "; then
                rm -rf "$dir"
                log_ok "Eliminado: $dir"
            else
                log_warn "$dir aún está montado, no se elimina"
            fi
        fi
    done
}

#===============================================================================
# INFORME FINAL
#===============================================================================
final_report() {
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}✅ DAS LIMPIADO COMPLETAMENTE${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    echo -e "${YELLOW}Estado del Volume Group:${NC}"
    vgs "$VG_NAME" 2>/dev/null || echo "  No existe"
    echo ""
    
    echo -e "${YELLOW}Physical Volumes:${NC}"
    pvs 2>/dev/null | grep -E "PV|$VG_NAME" || echo "  Ninguno"
    echo ""
    
    echo -e "${YELLOW}Espacio total disponible:${NC}"
    vgs --noheadings -o vg_free "$VG_NAME" 2>/dev/null | xargs echo "  " || echo "  N/A"
    echo ""
    
    echo "Próximo paso:"
    echo "  Ejecutar: sudo ./das-setup.sh"
    echo ""
}

#===============================================================================
# MAIN
#===============================================================================
main() {
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              DAS CLEANUP SCRIPT                            ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    check_root
    show_current_state
    confirm_cleanup
    
    stop_services
    cleanup_nfs
    unmount_volumes
    cleanup_fstab
    remove_logical_volumes
    cleanup_directories
    
    final_report
}

main "$@"