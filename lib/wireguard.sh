#!/usr/bin/env bash
# ==============================================================================
# wireguard.sh - модуль проверки состояния WireGuard
# ==============================================================================
# Зависимости: wireguard-tools (wg), iproute2

wg_module_available() {
    command -v wg &>/dev/null
}

wg_check() {
    msg_title "=== Проверка WireGuard ==="
    if ! wg_module_available; then
        msg_err "Утилита wg не найдена. Установите пакет: apt install wireguard-tools"
        log_action "CHECK" "wg" "-" "-" "FAIL" "wg not installed"
        return 1
    fi

    local ifaces
    ifaces="$(wg show interfaces 2>/dev/null)"
    if [[ -z "$ifaces" ]]; then
        msg_warn "Активных интерфейсов WireGuard не найдено."
        log_action "CHECK" "wg" "-" "-" "FAIL" "no interfaces"
        return 1
    fi

    local iface
    for iface in $ifaces; do
        echo
        msg_title "-- Интерфейс: $iface --"
        if iface_is_up "$iface"; then
            msg_ok "Интерфейс $iface поднят (UP)."
        else
            msg_err "Интерфейс $iface существует, но не поднят!"
        fi

        local cidr
        cidr="$(get_iface_cidr "$iface")"
        [[ -n "$cidr" ]] && msg_info "Адрес/подсеть: $cidr"

        echo
        printf "%-46s %-20s %-22s %-10s\n" "PUBLIC KEY" "ENDPOINT" "ALLOWED IPS" "HANDSHAKE"
        hr
        # wg show <if> dump выводит: private, public, endpoint, allowed-ips, latest-handshake, rx, tx, keepalive
        # первая строка - сам интерфейс (пропускаем)
        local first=1
        while IFS=$'\t' read -r pub psk endpoint allowed handshake rx tx keepalive; do
            if (( first == 1 )); then first=0; continue; fi
            local hs_human="никогда"
            if [[ "$handshake" != "0" && -n "$handshake" ]]; then
                local now diff
                now="$(date +%s)"
                diff=$(( now - handshake ))
                if (( diff < 180 )); then
                    hs_human="${diff}s назад ${C_GREEN}(активен)${C_RESET}"
                else
                    hs_human="${diff}s назад ${C_YELLOW}(давно)${C_RESET}"
                fi
            else
                hs_human="${C_RED}нет handshake${C_RESET}"
            fi
            printf "%-46s %-20s %-22s %b\n" "${pub:0:44}" "${endpoint:-—}" "$allowed" "$hs_human"

            # Маршрут до первого allowed IP (без маски)
            local ip_only
            ip_only="$(echo "$allowed" | cut -d, -f1 | cut -d/ -f1)"
            if [[ -n "$ip_only" ]]; then
                local rt
                rt="$(ip route get "$ip_only" 2>/dev/null | head -n1)"
                if [[ -n "$rt" ]]; then
                    msg_ok "  Маршрут до $ip_only: OK"
                else
                    msg_warn "  Нет маршрута до $ip_only"
                fi
            fi
        done < <(wg show "$iface" dump 2>/dev/null)
    done
    log_action "CHECK" "wg" "-" "-" "SUCCESS"
}

# Список известных IP клиентов WireGuard (allowed-ips всех peer'ов всех интерфейсов)
wg_list_client_ips() {
    wg_module_available || return 1
    local iface
    for iface in $(wg show interfaces 2>/dev/null); do
        wg show "$iface" allowed-ips 2>/dev/null | awk '{print $2}' | cut -d, -f1 | cut -d/ -f1
    done
}
