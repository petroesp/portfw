#!/usr/bin/env bash
# ==============================================================================
# backend_nftables.sh - реализация правил проброса портов через nftables
# ==============================================================================
# Зависимости: nftables (nft)
#
# Все правила живут в отдельной таблице `inet portfw`, которую утилита создаёт
# сама (идемпотентно). Это не конфликтует со сторонними таблицами (ufw,
# firewalld, docker), т.к. используется собственное пространство имён.
# Источник истины - `nft list ruleset` (без отдельного конфиг-файла проекта).

NFT_TABLE="inet portfw"
NFT_TAG_PREFIX="portfw"

_nft_tag() {
    echo "${NFT_TAG_PREFIX}:$1:$2:$3:$4:$5"
}

# Идемпотентно создаёт таблицу и цепочки, если их ещё нет
nft_ensure_table() {
    if ! nft list table inet portfw &>/dev/null; then
        nft add table inet portfw
    fi
    nft list chain inet portfw prerouting &>/dev/null || \
        nft add chain inet portfw prerouting '{ type nat hook prerouting priority -100 ; policy accept ; }'
    nft list chain inet portfw postrouting &>/dev/null || \
        nft add chain inet portfw postrouting '{ type nat hook postrouting priority 100 ; policy accept ; }'
    nft list chain inet portfw forward &>/dev/null || \
        nft add chain inet portfw forward '{ type filter hook forward priority 0 ; policy accept ; }'
}

nft_add_dnat() {
    local proto="$1" extport="$2" dstip="$3" dstport="$4" extiface="$5"
    nft_ensure_table
    local tag; tag="$(_nft_tag "$proto" "$extport" "$dstip" "$dstport" dnat)"
    if nft list chain inet portfw prerouting 2>/dev/null | grep -qF "$tag"; then
        msg_warn "DNAT-правило уже существует, пропускаю."
        return 0
    fi
    nft add rule inet portfw prerouting iifname "$extiface" "$proto" dport "$extport" \
        counter dnat to "${dstip}:${dstport}" comment \"$tag\"
}

nft_add_forward() {
    local proto="$1" extport="$2" dstip="$3" dstport="$4" extiface="$5" dstiface="$6"
    nft_ensure_table
    local tag; tag="$(_nft_tag "$proto" "$extport" "$dstip" "$dstport" fwd)"
    if nft list chain inet portfw forward 2>/dev/null | grep -qF "$tag"; then
        msg_warn "FORWARD-правило уже существует, пропускаю."
    else
        nft add rule inet portfw forward iifname "$extiface" oifname "$dstiface" ip daddr "$dstip" \
            "$proto" dport "$dstport" counter accept comment \"$tag\"
    fi
    nft_ensure_established
}

nft_ensure_established() {
    local tag="${NFT_TAG_PREFIX}:generic:0:0.0.0.0:0:established"
    nft_ensure_table
    if ! nft list chain inet portfw forward 2>/dev/null | grep -qF "$tag"; then
        nft insert rule inet portfw forward ct state established,related counter accept comment \"$tag\"
    fi
}

nft_add_masquerade() {
    local extiface="$1"
    nft_ensure_table
    local tag="${NFT_TAG_PREFIX}:generic:0:0.0.0.0:0:masq:${extiface}"
    if ! nft list chain inet portfw postrouting 2>/dev/null | grep -qF "$tag"; then
        nft add rule inet portfw postrouting oifname "$extiface" counter masquerade comment \"$tag\"
    fi
}

nft_add_hairpin() {
    local proto="$1" extport="$2" dstip="$3" dstport="$4" dstiface="$5"
    nft_ensure_table
    local subnet tag
    subnet="$(get_iface_cidr "$dstiface")"
    [[ -z "$subnet" ]] && { msg_warn "Не удалось определить подсеть $dstiface, hairpin NAT пропущен."; return 1; }
    tag="$(_nft_tag "$proto" "$extport" "$dstip" "$dstport" hairpin)"
    if nft list chain inet portfw postrouting 2>/dev/null | grep -qF "$tag"; then
        msg_warn "Hairpin-правило уже существует, пропускаю."
    else
        nft add rule inet portfw postrouting ip saddr "$subnet" ip daddr "$dstip" "$proto" dport "$dstport" \
            counter masquerade comment \"$tag\"
    fi
}

# Удаление правил по тегу через handle
_nft_delete_by_tag_in_chain() {
    local chain="$1" tag="$2"
    local handle
    handle="$(nft -a list chain inet portfw "$chain" 2>/dev/null | grep -F "$tag" | grep -oP '(?<=handle )[0-9]+')"
    local h found=1
    for h in $handle; do
        nft delete rule inet portfw "$chain" handle "$h" && found=0
    done
    return $found
}

nft_remove_ruleset() {
    local proto="$1" extport="$2" dstip="$3" dstport="$4"
    local removed=1
    _nft_delete_by_tag_in_chain prerouting  "$(_nft_tag "$proto" "$extport" "$dstip" "$dstport" dnat)"    && removed=0
    _nft_delete_by_tag_in_chain forward     "$(_nft_tag "$proto" "$extport" "$dstip" "$dstport" fwd)"     && removed=0
    _nft_delete_by_tag_in_chain postrouting "$(_nft_tag "$proto" "$extport" "$dstip" "$dstport" hairpin)" && removed=0
    (( removed == 0 ))
}

# Вывод (tab-separated): proto extport dstip dstport role table(=inet) chain pkts bytes
nft_list_rules() {
    nft -a list table inet portfw 2>/dev/null | awk -v prefix="${NFT_TAG_PREFIX}:" '
        /^\tchain / { chain=$2; next }
        index($0, prefix) {
            pkts=0; bytes=0
            if (match($0, /packets [0-9]+ bytes [0-9]+/)) {
                s=substr($0, RSTART, RLENGTH)
                split(s, a, " ")
                pkts=a[2]; bytes=a[4]
            }
            if (match($0, prefix "[^\"]+")) {
                tag = substr($0, RSTART, RLENGTH)
                n = split(tag, parts, ":")
                proto=parts[2]; extport=parts[3]; dstip=parts[4]; dstport=parts[5]; role=parts[6]
                printf "%s\t%s\t%s\t%s\t%s\tinet\t%s\t%d\t%d\n", proto, extport, dstip, dstport, role, chain, pkts, bytes
            }
        }
    '
}

nft_save() {
    local target="/etc/nftables.conf"
    if [[ -f "$target" ]]; then
        cp "$target" "${target}.bak.$(date +%s)"
    fi
    nft list ruleset > "$target"
    msg_info "Правила записаны в $target."
    if systemctl is-enabled nftables &>/dev/null; then
        msg_ok "Сервис nftables.service включён - правила восстановятся при загрузке."
    else
        msg_warn "Сервис nftables.service не включён. Выполните: systemctl enable nftables"
    fi
}

nft_backup() {
    local file="$1"
    nft list ruleset > "$file"
}

nft_restore() {
    local file="$1"
    nft -f "$file"
}
