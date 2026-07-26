#!/usr/bin/env bash
# ==============================================================================
# connectivity.sh - автоматическая проверка доступности после добавления правила
# ==============================================================================
# Зависимости: iproute2 (ip), iputils-ping (ping), netcat-openbsd (nc), curl
# Все проверки best-effort и не считаются фатальными - только информируют.

check_connectivity() {
    local dstip="$1" dstport_raw="$2" proto="$3"
    local dstport="${dstport_raw%%-*}"   # для диапазона берём первый порт

    msg_title "Проверка доступности $dstip:$dstport ($proto)"

    # 1. Маршрут
    local route
    route="$(ip route get "$dstip" 2>/dev/null)"
    if [[ -n "$route" ]]; then
        msg_ok "Маршрут найден: $(echo "$route" | head -n1)"
    else
        msg_err "Маршрут до $dstip не найден."
        log_action "CHECK" "$proto" "$dstport_raw" "$dstip" "FAIL" "no route"
        return 1
    fi

    # 2. Ping
    if command -v ping &>/dev/null; then
        if ping -c 2 -W 1 "$dstip" &>/dev/null; then
            msg_ok "Хост $dstip отвечает на ping."
        else
            msg_warn "Хост $dstip не отвечает на ping (может быть заблокирован ICMP на устройстве)."
        fi
    fi

    # 3. Проверка порта через nc
    if command -v nc &>/dev/null; then
        local nc_flags="-z -w2"
        [[ "$proto" == "udp" ]] && nc_flags="-z -u -w2"
        if nc $nc_flags "$dstip" "$dstport" &>/dev/null; then
            msg_ok "Порт $dstport/$proto на $dstip открыт и принимает соединения."
        else
            msg_warn "Порт $dstport/$proto на $dstip не отвечает (сервис может быть ещё не запущен)."
        fi
    else
        msg_warn "nc (netcat) не установлен - пропускаю проверку порта. apt install netcat-openbsd"
    fi

    # 4. HTTP проверка (только если похоже на веб-порт, и только TCP)
    if [[ "$proto" == "tcp" ]] && command -v curl &>/dev/null; then
        case "$dstport" in
            80|8080|8000|8443|443|3000|5000|9000)
                local scheme="http"
                [[ "$dstport" == "443" || "$dstport" == "8443" ]] && scheme="https"
                if curl -sk -m 3 -o /dev/null -w "%{http_code}" "${scheme}://${dstip}:${dstport}" 2>/dev/null | grep -qE '^[0-9]{3}$'; then
                    msg_ok "HTTP(S)-ответ получен от ${scheme}://${dstip}:${dstport}"
                else
                    msg_warn "HTTP(S) недоступен на ${scheme}://${dstip}:${dstport} (это нормально, если это не веб-сервис)."
                fi
                ;;
        esac
    fi

    log_action "CHECK" "$proto" "$dstport_raw" "$dstip" "SUCCESS"
}

# Полная проверка доступности по запросу пользователя (пункт меню 9)
manual_connectivity_check() {
    read -r -p "IP устройства: " ip
    if ! is_valid_ipv4 "$ip"; then msg_err "Некорректный IP."; return; fi
    read -r -p "Порт: " port
    if ! is_valid_port "$port"; then msg_err "Некорректный порт."; return; fi
    read -r -p "Протокол (tcp/udp) [tcp]: " proto
    proto="${proto:-tcp}"
    check_connectivity "$ip" "$port" "$proto"
}
