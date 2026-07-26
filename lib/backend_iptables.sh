#!/usr/bin/env bash
# ==============================================================================
# backend_iptables.sh - реализация правил проброса портов через iptables
# ==============================================================================
# Зависимости: iptables, iptables-save, iptables-restore (пакет iptables)
#
# Модель тегирования: каждое правило помечается комментарием вида
#   portfw:<proto>:<extport>:<dstip>:<dstport>:<role>
# где role = dnat | fwd | hairpin | established | masq
# Это единственный источник истины - отдельный конфиг не используется,
# все данные восстанавливаются парсингом `iptables-save`.

IPT_TAG_PREFIX="portfw"

_ipt_tag() {
    # proto extport dstip dstport role
    echo "${IPT_TAG_PREFIX}:$1:$2:$3:$4:$5"
}

# Проверяет, существует ли уже правило с данным набором аргументов (точное совпадение)
_ipt_rule_exists() {
    local table="$1" chain="$2"; shift 2
    iptables -t "$table" -C "$chain" "$@" &>/dev/null
}

ipt_add_dnat() {
    local proto="$1" extport="$2" dstip="$3" dstport="$4" extiface="$5"
    local dport_colon dport_dash tag
    dport_colon="$(port_range_to_colon "$extport")"
    dport_dash="$extport"
    tag="$(_ipt_tag "$proto" "$extport" "$dstip" "$dstport" dnat)"
    local to_dest="$dstip:$dstport"

    local args=(-i "$extiface" -p "$proto" --dport "$dport_colon" -j DNAT --to-destination "$to_dest" -m comment --comment "$tag")
    if _ipt_rule_exists nat PREROUTING "${args[@]}"; then
        msg_warn "DNAT-правило уже существует, пропускаю."
        return 0
    fi
    iptables -t nat -A PREROUTING "${args[@]}"
}

ipt_add_forward() {
    local proto="$1" extport="$2" dstip="$3" dstport="$4" extiface="$5" dstiface="$6"
    local dport_colon tag
    dport_colon="$(port_range_to_colon "$dstport")"
    tag="$(_ipt_tag "$proto" "$extport" "$dstip" "$dstport" fwd)"

    local args=(-i "$extiface" -o "$dstiface" -p "$proto" -d "$dstip" --dport "$dport_colon" -j ACCEPT -m comment --comment "$tag")
    if _ipt_rule_exists filter FORWARD "${args[@]}"; then
        msg_warn "FORWARD-правило уже существует, пропускаю."
    else
        iptables -A FORWARD "${args[@]}"
    fi
    ipt_ensure_established
}

# Общее правило разрешения обратного трафика ESTABLISHED,RELATED (создаётся один раз)
ipt_ensure_established() {
    local tag="${IPT_TAG_PREFIX}:generic:0:0.0.0.0:0:established"
    if ! iptables -C FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT -m comment --comment "$tag" &>/dev/null; then
        iptables -I FORWARD 1 -m state --state ESTABLISHED,RELATED -j ACCEPT -m comment --comment "$tag"
    fi
}

# MASQUERADE для исходящего трафика через внешний интерфейс (создаётся один раз на интерфейс)
ipt_add_masquerade() {
    local extiface="$1"
    local tag="${IPT_TAG_PREFIX}:generic:0:0.0.0.0:0:masq:${extiface}"
    if ! iptables -t nat -C POSTROUTING -o "$extiface" -j MASQUERADE -m comment --comment "$tag" &>/dev/null; then
        iptables -t nat -A POSTROUTING -o "$extiface" -j MASQUERADE -m comment --comment "$tag"
    fi
}

# Hairpin NAT: клиент внутри WireGuard стучится на публичный IP -> тоже должен попадать
# на пробрасываемое устройство. Для этого источник тоже маскируется.
ipt_add_hairpin() {
    local proto="$1" extport="$2" dstip="$3" dstport="$4" dstiface="$5"
    local subnet dport_colon tag
    subnet="$(get_iface_cidr "$dstiface")"
    [[ -z "$subnet" ]] && { msg_warn "Не удалось определить подсеть $dstiface, hairpin NAT пропущен."; return 1; }
    dport_colon="$(port_range_to_colon "$dstport")"
    tag="$(_ipt_tag "$proto" "$extport" "$dstip" "$dstport" hairpin)"

    local args=(-s "$subnet" -d "$dstip" -p "$proto" --dport "$dport_colon" -j MASQUERADE -m comment --comment "$tag")
    if _ipt_rule_exists nat POSTROUTING "${args[@]}"; then
        msg_warn "Hairpin-правило уже существует, пропускаю."
    else
        iptables -t nat -A POSTROUTING "${args[@]}"
    fi
}

# Удаление всего набора правил (dnat+fwd+hairpin) для заданного логического проброса.
# Пересчитывает интерфейсы заново (extiface/dstiface должны совпадать с моментом добавления).
ipt_remove_ruleset() {
    local proto="$1" extport="$2" dstip="$3" dstport="$4" extiface="$5" dstiface="$6"
    local dport_ext_colon dport_dst_colon
    dport_ext_colon="$(port_range_to_colon "$extport")"
    dport_dst_colon="$(port_range_to_colon "$dstport")"
    local subnet
    subnet="$(get_iface_cidr "$dstiface")"

    local removed=0

    local dnat_tag="$(_ipt_tag "$proto" "$extport" "$dstip" "$dstport" dnat)"
    if iptables -t nat -D PREROUTING -i "$extiface" -p "$proto" --dport "$dport_ext_colon" \
        -j DNAT --to-destination "$dstip:$dstport" -m comment --comment "$dnat_tag" 2>/dev/null; then
        removed=1
    fi

    local fwd_tag="$(_ipt_tag "$proto" "$extport" "$dstip" "$dstport" fwd)"
    if iptables -D FORWARD -i "$extiface" -o "$dstiface" -p "$proto" -d "$dstip" --dport "$dport_dst_colon" \
        -j ACCEPT -m comment --comment "$fwd_tag" 2>/dev/null; then
        removed=1
    fi

    if [[ -n "$subnet" ]]; then
        local hp_tag="$(_ipt_tag "$proto" "$extport" "$dstip" "$dstport" hairpin)"
        if iptables -t nat -D POSTROUTING -s "$subnet" -d "$dstip" -p "$proto" --dport "$dport_dst_colon" \
            -j MASQUERADE -m comment --comment "$hp_tag" 2>/dev/null; then
            removed=1
        fi
    fi

    (( removed == 1 ))
}

# Список активных правил проброса, распарсенных из iptables-save.
# Вывод (tab-separated): proto extport dstip dstport role table chain pkts bytes
# ВАЖНО: iptables-save -c ставит счётчики [pkts:bytes] ПЕРЕД "-A ...", поэтому
# строка не начинается с "-A" - её нужно искать по подстроке, а не по началу.
ipt_list_rules() {
    iptables-save -c 2>/dev/null | awk -v prefix="${IPT_TAG_PREFIX}:" '
        /^\*/ { table=substr($1,2); next }
        (/^-A / || /^\[[0-9]+:[0-9]+\] -A /) && index($0, prefix) {
            # вытащить счётчики [pkts:bytes], если есть
            pkts=0; bytes=0
            if (match($0, /\[[0-9]+:[0-9]+\]/)) {
                cnt = substr($0, RSTART+1, RLENGTH-2)
                split(cnt, c, ":")
                pkts=c[1]; bytes=c[2]
            }
            # найти chain: слово, идущее сразу после токена "-A"
            n = split($0, f, " ")
            chain=""
            for (i=1; i<=n; i++) {
                if (f[i] == "-A") { chain=f[i+1]; break }
            }
            # вытащить тег portfw:...
            if (match($0, prefix "[^ \"]+")) {
                tag = substr($0, RSTART, RLENGTH)
                split(tag, parts, ":")
                proto=parts[2]; extport=parts[3]; dstip=parts[4]; dstport=parts[5]; role=parts[6]
                printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%d\n", proto, extport, dstip, dstport, role, table, chain, pkts, bytes
            }
        }
    '
}

ipt_save() {
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save &>/dev/null && return 0
    fi
    if [[ -d /etc/iptables ]]; then
        iptables-save > /etc/iptables/rules.v4
        return $?
    fi
    msg_warn "netfilter-persistent не найден. Правила сохранены в ядре, но НЕ переживут перезагрузку."
    msg_warn "Установите пакет iptables-persistent для автосохранения: apt install iptables-persistent"
    return 1
}

ipt_backup() {
    local file="$1"
    iptables-save > "$file"
}

ipt_restore() {
    local file="$1"
    iptables-restore < "$file"
}
