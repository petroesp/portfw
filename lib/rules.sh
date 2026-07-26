#!/usr/bin/env bash
# ==============================================================================
# rules.sh - высокоуровневая логика управления пробросами портов
# ==============================================================================
# Опирается на backend.sh (fw_*) и utils.sh. Не хранит состояние сама -
# при каждом обращении опрашивает firewall (fw_list_rules).

_port_bounds() {
    # "8080" -> "8080 8080"; "5000-5100" -> "5000 5100"
    local v="$1"
    if [[ "$v" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
    else
        echo "$v $v"
    fi
}

_ranges_overlap() {
    local a1 a2 b1 b2
    read -r a1 a2 <<< "$(_port_bounds "$1")"
    read -r b1 b2 <<< "$(_port_bounds "$2")"
    ! (( a2 < b1 || b2 < a1 ))
}

# Проверка конфликта: есть ли уже DNAT-правило на этот proto/extport, ведущее в ДРУГОЕ место
check_port_conflict() {
    local proto="$1" extport="$2"
    local line rproto rextport rdstip rdstport rrole
    while IFS=$'\t' read -r rproto rextport rdstip rdstport rrole _ _ _ _; do
        [[ "$rrole" != "dnat" ]] && continue
        [[ "$rproto" != "$proto" ]] && continue
        if _ranges_overlap "$extport" "$rextport"; then
            echo "$rextport -> $rdstip:$rdstport"
            return 0
        fi
    done < <(fw_list_rules)
    return 1
}

# Полное добавление проброса для ОДНОГО протокола (tcp|udp)
_add_single_proto_forward() {
    local proto="$1" extport="$2" dstip="$3" dstport="$4"

    local conflict
    if conflict="$(check_port_conflict "$proto" "$extport")"; then
        msg_warn "Конфликт: порт $extport/$proto уже проброшен -> $conflict"
        if ! confirm "Всё равно продолжить и добавить ещё одно правило?"; then
            msg_info "Пропущено: $proto/$extport"
            log_action "ADD" "$proto" "$extport" "$dstip:$dstport" "SKIP" "conflict with $conflict"
            return 1
        fi
    fi

    local extiface dstiface
    extiface="$(get_default_iface)"
    if [[ -z "$extiface" ]]; then
        msg_err "Не удалось определить внешний интерфейс (default route)."
        log_action "ADD" "$proto" "$extport" "$dstip:$dstport" "FAIL" "no default iface"
        return 1
    fi
    dstiface="$(get_route_iface "$dstip")"
    if [[ -z "$dstiface" ]]; then
        msg_err "Не удалось определить интерфейс маршрута до $dstip (ip route get $dstip)."
        log_action "ADD" "$proto" "$extport" "$dstip:$dstport" "FAIL" "no route to $dstip"
        return 1
    fi

    msg_info "Внешний интерфейс: $extiface | Интерфейс назначения ($dstip): $dstiface"

    fw_add_dnat "$proto" "$extport" "$dstip" "$dstport" "$extiface"
    fw_add_forward "$proto" "$extport" "$dstip" "$dstport" "$extiface" "$dstiface"
    fw_add_masquerade "$extiface"
    fw_add_hairpin "$proto" "$extport" "$dstip" "$dstport" "$dstiface"

    msg_ok "Правило добавлено: $extiface:$extport/$proto -> $dstip:$dstport (via $dstiface)"
    log_action "ADD" "$proto" "$extport" "$dstip:$dstport" "SUCCESS" "ext=$extiface dst_if=$dstiface"
    return 0
}

# Публичная функция: proto может быть tcp|udp|both
add_port_forward() {
    local proto="$1" extport="$2" dstip="$3" dstport="$4"
    local protos=()
    if [[ "$proto" == "both" ]]; then protos=(tcp udp); else protos=("$proto"); fi

    ensure_ip_forward_enabled

    local p ok=1
    for p in "${protos[@]}"; do
        _add_single_proto_forward "$p" "$extport" "$dstip" "$dstport" && ok=0
    done

    if (( ok == 0 )); then
        check_connectivity "$dstip" "$dstport" "${protos[0]}"
    fi
}

ensure_ip_forward_enabled() {
    local cur
    cur="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)"
    if [[ "$cur" != "1" ]]; then
        msg_warn "IP forward выключен (net.ipv4.ip_forward=0). Без него проброс работать не будет."
        if confirm "Включить IP forward сейчас и на постоянку?"; then
            sysctl -w net.ipv4.ip_forward=1 >/dev/null
            echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-portfw.conf
            sysctl --system &>/dev/null
            msg_ok "IP forward включён."
        fi
    fi
}

# --- Удаление / изменение ---------------------------------------------------

# Возвращает список логических пробросов (по одной строке на роль dnat),
# нумерованный, для меню выбора.
list_logical_rules() {
    fw_list_rules | awk -F'\t' '$5=="dnat"{print}'
}

remove_port_forward_interactive() {
    local rules
    mapfile -t rules < <(list_logical_rules)
    if (( ${#rules[@]} == 0 )); then
        msg_info "Активных пробросов не найдено."
        return
    fi

    echo "Список активных пробросов:"
    local i=1 line
    for line in "${rules[@]}"; do
        IFS=$'\t' read -r proto extport dstip dstport role table chain pkts bytes <<< "$line"
        printf "  %2d) %s/%s -> %s:%s  (%s пакетов)\n" "$i" "$extport" "$proto" "$dstip" "$dstport" "$pkts"
        ((i++))
    done

    read -r -p "Номер проброса для удаления (0 - отмена): " choice
    [[ "$choice" == "0" || -z "$choice" ]] && return
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#rules[@]} )); then
        msg_err "Неверный выбор."
        return
    fi

    IFS=$'\t' read -r proto extport dstip dstport role table chain pkts bytes <<< "${rules[$((choice-1))]}"
    _do_remove "$proto" "$extport" "$dstip" "$dstport"
}

_do_remove() {
    local proto="$1" extport="$2" dstip="$3" dstport="$4"
    local extiface dstiface
    extiface="$(get_default_iface)"
    dstiface="$(get_route_iface "$dstip")"

    if fw_remove_ruleset "$proto" "$extport" "$dstip" "$dstport" "$extiface" "$dstiface"; then
        msg_ok "Правило удалено: $extport/$proto -> $dstip:$dstport"
        log_action "DEL" "$proto" "$extport" "$dstip:$dstport" "SUCCESS"
    else
        msg_err "Не удалось удалить правило (возможно, интерфейсы изменились с момента создания)."
        log_action "DEL" "$proto" "$extport" "$dstip:$dstport" "FAIL"
    fi
}

edit_port_forward_interactive() {
    local rules
    mapfile -t rules < <(list_logical_rules)
    if (( ${#rules[@]} == 0 )); then
        msg_info "Активных пробросов не найдено."
        return
    fi

    echo "Список активных пробросов:"
    local i=1 line
    for line in "${rules[@]}"; do
        IFS=$'\t' read -r proto extport dstip dstport role table chain pkts bytes <<< "$line"
        printf "  %2d) %s/%s -> %s:%s\n" "$i" "$extport" "$proto" "$dstip" "$dstport"
        ((i++))
    done

    read -r -p "Номер проброса для изменения (0 - отмена): " choice
    [[ "$choice" == "0" || -z "$choice" ]] && return
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#rules[@]} )); then
        msg_err "Неверный выбор."
        return
    fi

    IFS=$'\t' read -r proto extport dstip dstport role table chain pkts bytes <<< "${rules[$((choice-1))]}"
    msg_info "Текущее правило: $extport/$proto -> $dstip:$dstport"

    read -r -p "Новый внешний порт [$extport]: " new_extport
    new_extport="${new_extport:-$extport}"
    read -r -p "Новый IP назначения [$dstip]: " new_dstip
    new_dstip="${new_dstip:-$dstip}"
    read -r -p "Новый порт назначения [$dstport]: " new_dstport
    new_dstport="${new_dstport:-$dstport}"

    if ! is_valid_port_or_range "$new_extport"; then msg_err "Некорректный внешний порт."; return; fi
    if ! is_valid_ipv4 "$new_dstip"; then msg_err "Некорректный IP назначения."; return; fi
    if ! is_valid_port_or_range "$new_dstport"; then msg_err "Некорректный порт назначения."; return; fi

    _do_remove "$proto" "$extport" "$dstip" "$dstport"
    add_port_forward "$proto" "$new_extport" "$new_dstip" "$new_dstport"
    log_action "EDIT" "$proto" "$extport->$new_extport" "$dstip:$dstport->$new_dstip:$new_dstport" "SUCCESS"
}

# --- Отображение -------------------------------------------------------------

show_active_rules() {
    local rows
    rows="$(fw_list_rules)"
    if [[ -z "$rows" ]]; then
        msg_info "Активных правил проброса не найдено."
        return
    fi

    printf "%-6s %-14s %-16s %-10s %-9s %-10s %10s %14s\n" \
        "PROTO" "EXT PORT" "DST IP" "DST PORT" "ROLE" "СЕРВИС" "ПАКЕТЫ" "БАЙТЫ"
    hr
    local line proto extport dstip dstport role table chain pkts bytes
    while IFS=$'\t' read -r proto extport dstip dstport role table chain pkts bytes; do
        local svc
        svc="$(service_name_for_port "${extport%%-*}" "$proto")"
        printf "%-6s %-14s %-16s %-10s %-9s %-10s %10s %14s\n" \
            "$proto" "$extport" "$dstip" "$dstport" "$role" "$svc" "$pkts" "$bytes"
    done <<< "$rows"
}
