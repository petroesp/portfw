#!/usr/bin/env bash
# ==============================================================================
# backend.sh - выбор и единый интерфейс firewall backend (nftables/iptables)
# ==============================================================================
# Логика: если доступен nftables (бинарь есть и подсистема отвечает) -> nft.
# Иначе -> iptables. Определяется один раз при старте (BACKEND глобальная).

detect_backend() {
    if command -v nft &>/dev/null && nft list ruleset &>/dev/null; then
        BACKEND="nftables"
    elif command -v iptables &>/dev/null; then
        BACKEND="iptables"
    else
        msg_err "Не найден ни nftables, ни iptables. Установите один из пакетов: nftables или iptables."
        exit 1
    fi
    export BACKEND
}

# --- Единый API, вызываемый остальными модулями ---------------------------

fw_add_dnat() {       # proto extport dstip dstport extiface
    if [[ "$BACKEND" == "nftables" ]]; then nft_add_dnat "$@"; else ipt_add_dnat "$@"; fi
}

fw_add_forward() {    # proto extport dstip dstport extiface dstiface
    if [[ "$BACKEND" == "nftables" ]]; then nft_add_forward "$@"; else ipt_add_forward "$@"; fi
}

fw_add_masquerade() { # extiface
    if [[ "$BACKEND" == "nftables" ]]; then nft_add_masquerade "$@"; else ipt_add_masquerade "$@"; fi
}

fw_add_hairpin() {    # proto extport dstip dstport dstiface
    if [[ "$BACKEND" == "nftables" ]]; then nft_add_hairpin "$@"; else ipt_add_hairpin "$@"; fi
}

fw_remove_ruleset() { # proto extport dstip dstport extiface dstiface
    if [[ "$BACKEND" == "nftables" ]]; then
        nft_remove_ruleset "$1" "$2" "$3" "$4"
    else
        ipt_remove_ruleset "$1" "$2" "$3" "$4" "$5" "$6"
    fi
}

fw_list_rules() {     # -> proto\textport\tdstip\tdstport\trole\ttable\tchain\tpkts\tbytes
    if [[ "$BACKEND" == "nftables" ]]; then nft_list_rules; else ipt_list_rules; fi
}

fw_save() {
    if [[ "$BACKEND" == "nftables" ]]; then nft_save; else ipt_save; fi
}

fw_backup() {          # file
    if [[ "$BACKEND" == "nftables" ]]; then nft_backup "$1"; else ipt_backup "$1"; fi
}

fw_restore() {         # file
    if [[ "$BACKEND" == "nftables" ]]; then nft_restore "$1"; else ipt_restore "$1"; fi
}

fw_ruleset_dump() {
    if [[ "$BACKEND" == "nftables" ]]; then nft list ruleset; else iptables-save; fi
}
