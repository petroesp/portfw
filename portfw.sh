#!/usr/bin/env bash
# ==============================================================================
# portfw.sh - Port Forward Manager
# ==============================================================================
# Консольная утилита управления DNAT-пробросами портов для Linux-шлюза
# (Debian/Ubuntu), работающего между интернетом и устройствами за WireGuard.
#
# Запуск:  sudo ./portfw.sh
# ==============================================================================

set -uo pipefail

SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_PATH")" &>/dev/null && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

# shellcheck source=lib/colors.sh
source "${LIB_DIR}/colors.sh"
# shellcheck source=lib/log.sh
source "${LIB_DIR}/log.sh"
# shellcheck source=lib/utils.sh
source "${LIB_DIR}/utils.sh"
# shellcheck source=lib/backend_iptables.sh
source "${LIB_DIR}/backend_iptables.sh"
# shellcheck source=lib/backend_nftables.sh
source "${LIB_DIR}/backend_nftables.sh"
# shellcheck source=lib/backend.sh
source "${LIB_DIR}/backend.sh"
# shellcheck source=lib/rules.sh
source "${LIB_DIR}/rules.sh"
# shellcheck source=lib/connectivity.sh
source "${LIB_DIR}/connectivity.sh"
# shellcheck source=lib/diagnostics.sh
source "${LIB_DIR}/diagnostics.sh"
# shellcheck source=lib/wireguard.sh
source "${LIB_DIR}/wireguard.sh"
# shellcheck source=lib/backup.sh
source "${LIB_DIR}/backup.sh"

# --- Интерактивное добавление проброса --------------------------------------

menu_add_forward() {
    msg_title "=== Добавление проброса порта ==="

    local proto
    while true; do
        read -r -p "Протокол (tcp/udp/both) [tcp]: " proto
        proto="${proto:-tcp}"
        proto="${proto,,}"
        is_valid_proto "$proto" && break
        msg_err "Введите tcp, udp или both."
    done

    local extport
    while true; do
        read -r -p "Внешний порт (например 8080 или 5000-5100): " extport
        is_valid_port_or_range "$extport" && break
        msg_err "Некорректный порт/диапазон."
    done

    local dstip
    while true; do
        read -r -p "IP устройства назначения (внутри WireGuard, например 10.6.66.20): " dstip
        is_valid_ipv4 "$dstip" && break
        msg_err "Некорректный IP-адрес."
    done

    local dstport
    read -r -p "Порт назначения [${extport}]: " dstport
    dstport="${dstport:-$extport}"
    if ! is_valid_port_or_range "$dstport"; then
        msg_err "Некорректный порт/диапазон назначения."
        return
    fi

    # Если оба - диапазоны, размеры должны совпадать. Если один - диапазон,
    # а другой одиночный порт - тоже ошибка (неоднозначное отображение).
    local size_ext size_dst
    size_ext="$(port_range_size "$extport")"
    size_dst="$(port_range_size "$dstport")"
    if (( size_ext != size_dst )); then
        msg_err "Размер диапазона внешнего порта ($size_ext) не совпадает с размером диапазона назначения ($size_dst)."
        return
    fi

    echo
    msg_info "Итог: $(describe_port "$extport" "$proto") [$proto] -> ${dstip}:${dstport}"
    confirm "Создать это правило?" || { msg_info "Отменено."; return; }

    add_port_forward "$proto" "$extport" "$dstip" "$dstport"
}

# --- Главное меню -------------------------------------------------------------

print_main_menu() {
    echo
    hr
    msg_title " Port Forward Manager"
    printf " backend: %s\n" "$BACKEND"
    hr
    cat <<'EOF'
1.  Добавить проброс
2.  Удалить проброс
3.  Изменить проброс
4.  Показать активные правила

5.  Диагностика системы
6.  Проверка WireGuard
7.  Проверка Firewall
8.  Проверка маршрутов
9.  Проверка доступности

10. Сохранить правила
11. Резервная копия
12. Восстановление

13. Показать журнал
14. Экспорт диагностики в файл

0.  Выход
EOF
    hr
}

menu_check_firewall() {
    msg_title "=== Состояние Firewall ==="
    msg_info "Активный backend: $BACKEND"
    echo
    if [[ "$BACKEND" == "iptables" ]]; then
        msg_title "-- FORWARD chain --"
        iptables -L FORWARD -n -v --line-numbers 2>/dev/null
        echo
        msg_title "-- NAT PREROUTING --"
        iptables -t nat -L PREROUTING -n -v --line-numbers 2>/dev/null
        echo
        msg_title "-- NAT POSTROUTING --"
        iptables -t nat -L POSTROUTING -n -v --line-numbers 2>/dev/null
    else
        nft list table inet portfw 2>/dev/null || msg_info "Таблица inet portfw ещё не создана (пробросов пока нет)."
    fi
    log_action "CHECK" "firewall" "-" "-" "SUCCESS"
}

menu_check_routes() {
    msg_title "=== Маршрутизация ==="
    msg_title "-- Таблица маршрутов --"
    ip route show
    echo
    msg_title "-- Маршруты до активных клиентов WireGuard --"
    local ip found=0
    while read -r ip; do
        [[ -z "$ip" ]] && continue
        found=1
        local rt
        rt="$(ip route get "$ip" 2>/dev/null | head -n1)"
        if [[ -n "$rt" ]]; then
            msg_ok "$ip -> $rt"
        else
            msg_err "$ip -> маршрут не найден"
        fi
    done < <(wg_list_client_ips 2>/dev/null)
    (( found == 0 )) && msg_info "Клиенты WireGuard не найдены."
    log_action "CHECK" "routes" "-" "-" "SUCCESS"
}

main() {
    require_root
    detect_backend
    mkdir -p "$PORTFW_BACKUP_DIR" 2>/dev/null

    local choice
    while true; do
        print_main_menu
        read -r -p "Выберите пункт меню: " choice
        echo
        case "$choice" in
            1) menu_add_forward ;;
            2) remove_port_forward_interactive ;;
            3) edit_port_forward_interactive ;;
            4) show_active_rules ;;
            5) run_full_diagnostics ;;
            6) wg_check ;;
            7) menu_check_firewall ;;
            8) menu_check_routes ;;
            9) manual_connectivity_check ;;
            10) fw_save ; log_action "SAVE" "-" "-" "-" "SUCCESS" ;;
            11) backup_rules_interactive ;;
            12) restore_rules_interactive ;;
            13) log_show_tail 50 ;;
            14) export_diagnostics ;;
            0) msg_info "Выход."; exit 0 ;;
            *) msg_err "Неверный пункт меню." ;;
        esac
        pause
    done
}

main "$@"
