#!/usr/bin/env bash
# ==============================================================================
# backup.sh - резервное копирование и восстановление правил firewall
# ==============================================================================
# Использует штатные средства: iptables-save/iptables-restore либо
# nft list ruleset / nft -f. Файлы бэкапов хранятся в /var/backups/portfw/.

PORTFW_BACKUP_DIR="/var/backups/portfw"

backup_rules_interactive() {
    mkdir -p "$PORTFW_BACKUP_DIR"
    local ts file
    ts="$(date +%Y%m%d-%H%M%S)"
    file="${PORTFW_BACKUP_DIR}/portfw-${BACKEND}-${ts}.rules"

    if fw_backup "$file"; then
        chmod 600 "$file"
        msg_ok "Резервная копия создана: $file"
        log_action "BACKUP" "-" "-" "-" "SUCCESS" "$file"
    else
        msg_err "Не удалось создать резервную копию."
        log_action "BACKUP" "-" "-" "-" "FAIL"
    fi
}

list_backups() {
    mkdir -p "$PORTFW_BACKUP_DIR"
    local files
    mapfile -t files < <(ls -1t "$PORTFW_BACKUP_DIR" 2>/dev/null)
    if (( ${#files[@]} == 0 )); then
        msg_info "Резервных копий пока нет."
        return 1
    fi
    local i=1 f
    for f in "${files[@]}"; do
        printf "  %2d) %s\n" "$i" "$f"
        ((i++))
    done
    return 0
}

restore_rules_interactive() {
    if ! list_backups; then return; fi
    mapfile -t files < <(ls -1t "$PORTFW_BACKUP_DIR" 2>/dev/null)
    read -r -p "Номер резервной копии для восстановления (0 - отмена): " choice
    [[ "$choice" == "0" || -z "$choice" ]] && return
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#files[@]} )); then
        msg_err "Неверный выбор."
        return
    fi
    local file="${PORTFW_BACKUP_DIR}/${files[$((choice-1))]}"

    if [[ "$file" == *iptables* && "$BACKEND" != "iptables" ]]; then
        msg_warn "Эта копия сделана для iptables, а сейчас используется $BACKEND."
    elif [[ "$file" == *nftables* && "$BACKEND" != "nftables" ]]; then
        msg_warn "Эта копия сделана для nftables, а сейчас используется $BACKEND."
    fi

    if ! confirm "Восстановить правила из $file? Текущие правила будут заменены/дополнены"; then
        msg_info "Отменено."
        return
    fi

    if fw_restore "$file"; then
        msg_ok "Правила восстановлены из $file"
        log_action "RESTORE" "-" "-" "-" "SUCCESS" "$file"
    else
        msg_err "Ошибка при восстановлении правил."
        log_action "RESTORE" "-" "-" "-" "FAIL" "$file"
    fi
}
