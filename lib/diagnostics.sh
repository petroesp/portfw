#!/usr/bin/env bash
# ==============================================================================
# diagnostics.sh - диагностика системы для проброса портов через WireGuard
# ==============================================================================
# Проверяет: ip_forward, rp_filter, FORWARD/NAT правила, conntrack, WireGuard,
# состояние интерфейсов, маршрутизацию, наличие Docker/UFW/firewalld.
# При обнаружении проблемы предлагает исправление (где это безопасно).

DIAG_ISSUES=()   # список найденных проблем для отчёта/экспорта

_diag_record() {
    DIAG_ISSUES+=("$1")
}

diag_check_ip_forward() {
    local v
    v="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)"
    if [[ "$v" == "1" ]]; then
        msg_ok "IP Forward включён (net.ipv4.ip_forward=1)."
    else
        msg_err "IP Forward выключен. Без него пакеты между интерфейсами маршрутизироваться не будут."
        _diag_record "ip_forward выключен"
        if confirm "Исправить автоматически (включить и закрепить в /etc/sysctl.d/99-portfw.conf)?"; then
            sysctl -w net.ipv4.ip_forward=1 >/dev/null
            echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-portfw.conf
            sysctl --system &>/dev/null
            msg_ok "Исправлено."
        fi
    fi
}

diag_check_rp_filter() {
    local bad=0 iface v
    for iface in $(ip -o link show | awk -F': ' '{print $2}'); do
        [[ "$iface" == "lo" ]] && continue
        v="$(sysctl -n "net.ipv4.conf.${iface}.rp_filter" 2>/dev/null)"
        if [[ "$v" == "1" ]]; then
            msg_warn "rp_filter=1 (strict) на $iface - может дропать асимметричный трафик через WireGuard."
            bad=1
        fi
    done
    if (( bad == 0 )); then
        msg_ok "rp_filter не в строгом режиме на активных интерфейсах."
    else
        _diag_record "rp_filter в строгом режиме на одном или нескольких интерфейсах"
        if confirm "Переключить rp_filter в loose-режим (2) на всех интерфейсах?"; then
            for iface in $(ip -o link show | awk -F': ' '{print $2}'); do
                [[ "$iface" == "lo" ]] && continue
                sysctl -w "net.ipv4.conf.${iface}.rp_filter=2" &>/dev/null
            done
            {
                echo "net.ipv4.conf.default.rp_filter=2"
                echo "net.ipv4.conf.all.rp_filter=2"
            } > /etc/sysctl.d/99-portfw-rpfilter.conf
            sysctl --system &>/dev/null
            msg_ok "Исправлено."
        fi
    fi
}

diag_check_forward_rules() {
    local cnt
    cnt="$(fw_list_rules | awk -F'\t' '$5=="fwd"' | wc -l)"
    if (( cnt > 0 )); then
        msg_ok "Найдено правил FORWARD: $cnt."
    else
        msg_warn "Правил FORWARD (portfw) не найдено. Если пробросы ещё не создавались - это нормально."
        _diag_record "нет активных правил FORWARD"
    fi

    if [[ "$BACKEND" == "iptables" ]]; then
        local policy
        policy="$(iptables -L FORWARD -n 2>/dev/null | head -n1 | grep -oP '(?<=policy )\S+(?=\))')"
        if [[ "$policy" == "DROP" || "$policy" == "REJECT" ]]; then
            msg_warn "Политика FORWARD по умолчанию: $policy. Пробросы будут работать только при наличии явных ACCEPT-правил (это нормально, если они есть)."
        fi
    fi
}

diag_check_nat_rules() {
    local cnt
    cnt="$(fw_list_rules | awk -F'\t' '$5=="dnat"' | wc -l)"
    if (( cnt > 0 )); then
        msg_ok "Найдено DNAT-правил: $cnt."
    else
        msg_info "DNAT-правил пока нет."
    fi
}

diag_check_conntrack() {
    if [[ -r /proc/net/nf_conntrack || -r /proc/net/ip_conntrack ]]; then
        msg_ok "Модуль conntrack загружен и работает."
    elif lsmod 2>/dev/null | grep -q nf_conntrack; then
        msg_ok "Модуль nf_conntrack загружен."
    else
        msg_warn "Модуль conntrack не обнаружен. NAT/FORWARD с отслеживанием состояний может работать некорректно."
        _diag_record "conntrack не обнаружен"
        if confirm "Попробовать загрузить модуль nf_conntrack сейчас?"; then
            modprobe nf_conntrack 2>/dev/null && msg_ok "Модуль загружен." || msg_err "Не удалось загрузить модуль."
        fi
    fi
}

diag_check_wireguard() {
    if ! command -v wg &>/dev/null; then
        msg_warn "Утилита wg не установлена (пакет wireguard-tools). WireGuard может не работать."
        _diag_record "wireguard-tools не установлен"
        return
    fi
    local ifaces
    ifaces="$(wg show interfaces 2>/dev/null)"
    if [[ -z "$ifaces" ]]; then
        msg_warn "WireGuard интерфейсы не найдены (wg show interfaces пусто)."
        _diag_record "нет активных WireGuard интерфейсов"
    else
        msg_ok "WireGuard интерфейсы: $ifaces"
    fi
}

diag_check_interfaces() {
    local up down
    up="$(ip -o link show up | wc -l)"
    down="$(ip -o link show down | grep -v ' lo:' | wc -l)"
    msg_info "Активных (UP) интерфейсов: $up, выключенных: $down."
    local ext
    ext="$(get_default_iface)"
    if [[ -n "$ext" ]]; then
        msg_ok "Внешний интерфейс (default route): $ext"
    else
        msg_err "Не удалось определить внешний интерфейс - нет маршрута по умолчанию!"
        _diag_record "нет default route"
    fi
}

diag_check_routing() {
    if ip -4 route show default &>/dev/null && [[ -n "$(ip -4 route show default)" ]]; then
        msg_ok "Маршрут по умолчанию настроен: $(ip -4 route show default | head -n1)"
    else
        msg_err "Маршрут по умолчанию отсутствует."
        _diag_record "нет default route"
    fi
}

diag_check_docker() {
    if command -v docker &>/dev/null; then
        msg_warn "Обнаружен Docker. Docker может сам управлять iptables (цепочка DOCKER) и конфликтовать с ручными правилами FORWARD/NAT."
        _diag_record "обнаружен Docker - возможен конфликт правил"
    else
        msg_ok "Docker не обнаружен."
    fi
}

diag_check_ufw() {
    if command -v ufw &>/dev/null; then
        local st
        st="$(ufw status 2>/dev/null | head -n1)"
        if [[ "$st" == *active* ]]; then
            msg_warn "UFW активен ($st). UFW может перезаписывать/блокировать правила iptables, добавленные вручную."
            _diag_record "UFW активен и может конфликтовать"
        else
            msg_ok "UFW установлен, но неактивен."
        fi
    else
        msg_ok "UFW не установлен."
    fi
}

diag_check_firewalld() {
    if command -v firewall-cmd &>/dev/null; then
        if systemctl is-active firewalld &>/dev/null; then
            msg_warn "firewalld активен. Он использует nftables/iptables через собственные зоны и может конфликтовать с ручными правилами."
            _diag_record "firewalld активен и может конфликтовать"
        else
            msg_ok "firewalld установлен, но неактивен."
        fi
    else
        msg_ok "firewalld не установлен."
    fi
}

diag_check_backend_conflict() {
    if command -v nft &>/dev/null && command -v iptables &>/dev/null; then
        if iptables -V 2>/dev/null | grep -qi "nf_tables"; then
            msg_info "iptables работает поверх nf_tables (iptables-nft) - конфликтов между backend'ами не будет."
        else
            msg_info "В системе установлены и iptables (legacy), и nftables. Утилита использует: $BACKEND."
        fi
    fi
}

run_full_diagnostics() {
    DIAG_ISSUES=()
    msg_title "=== Диагностика системы Port Forward Manager ==="
    echo
    msg_title "-- IP Forward --";        diag_check_ip_forward
    echo
    msg_title "-- rp_filter --";         diag_check_rp_filter
    echo
    msg_title "-- FORWARD правила --";   diag_check_forward_rules
    echo
    msg_title "-- NAT правила --";       diag_check_nat_rules
    echo
    msg_title "-- Conntrack --";         diag_check_conntrack
    echo
    msg_title "-- WireGuard --";         diag_check_wireguard
    echo
    msg_title "-- Интерфейсы --";        diag_check_interfaces
    echo
    msg_title "-- Маршрутизация --";     diag_check_routing
    echo
    msg_title "-- Docker --";            diag_check_docker
    echo
    msg_title "-- UFW --";               diag_check_ufw
    echo
    msg_title "-- firewalld --";         diag_check_firewalld
    echo
    msg_title "-- Firewall backend --";  diag_check_backend_conflict
    echo
    hr
    if (( ${#DIAG_ISSUES[@]} == 0 )); then
        msg_ok "Проблем не обнаружено."
    else
        msg_warn "Обнаружено проблем: ${#DIAG_ISSUES[@]}"
        local issue
        for issue in "${DIAG_ISSUES[@]}"; do
            echo "  - $issue"
        done
    fi
    log_action "DIAG" "-" "-" "-" "INFO" "issues=${#DIAG_ISSUES[@]}"
}

# Экспорт полной диагностики в файл (пункт "дополнительно": экспорт диагностики)
export_diagnostics() {
    local outfile="/root/portfw-diag-$(date +%Y%m%d-%H%M%S).txt"
    {
        echo "Port Forward Manager - отчёт диагностики"
        echo "Дата: $(date)"
        echo "Backend: $BACKEND"
        echo
        echo "### sysctl ###"
        sysctl net.ipv4.ip_forward 2>/dev/null
        sysctl net.ipv4.conf.all.rp_filter net.ipv4.conf.default.rp_filter 2>/dev/null
        echo
        echo "### Интерфейсы ###"
        ip -4 addr show
        echo
        echo "### Маршруты ###"
        ip route show
        echo
        echo "### Активные правила проброса ###"
        fw_list_rules
        echo
        echo "### Полный дамп firewall ###"
        fw_ruleset_dump
        echo
        echo "### WireGuard ###"
        wg show 2>/dev/null || echo "wg не установлен или нет интерфейсов"
    } > "$outfile" 2>&1
    chmod 600 "$outfile"
    msg_ok "Диагностика экспортирована в $outfile"
    log_action "DIAG" "-" "-" "-" "SUCCESS" "exported to $outfile"
}
