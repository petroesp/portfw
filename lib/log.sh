#!/usr/bin/env bash
# ==============================================================================
# log.sh - журналирование действий Port Forward Manager
# ==============================================================================
# Пишет структурированный журнал в /var/log/portfw.log (либо в резервный путь,
# если нет прав на запись). Формат строки:
#   2026-07-26 15:30:00  ACTION   PROTO  PORT      TARGET               STATUS  [details]

PORTFW_LOG_PRIMARY="/var/log/portfw.log"
PORTFW_LOG_FALLBACK="${HOME:-/tmp}/portfw.log"

_portfw_log_path() {
    if [[ -w "$(dirname "$PORTFW_LOG_PRIMARY")" || -w "$PORTFW_LOG_PRIMARY" ]]; then
        echo "$PORTFW_LOG_PRIMARY"
    else
        echo "$PORTFW_LOG_FALLBACK"
    fi
}

PORTFW_LOG_FILE="$(_portfw_log_path)"

# log_action ACTION PROTO PORT TARGET STATUS [DETAILS]
# ACTION: ADD | DEL | EDIT | DIAG | BACKUP | RESTORE | CHECK | SAVE
# STATUS: SUCCESS | FAIL | INFO
log_action() {
    local action="$1" proto="${2:--}" port="${3:--}" target="${4:--}" status="${5:-INFO}" details="${6:-}"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    printf '%s\t%-7s\t%-8s\t%-10s\t%-22s\t%-7s\t%s\n' \
        "$ts" "$action" "$proto" "$port" "$target" "$status" "$details" >> "$PORTFW_LOG_FILE" 2>/dev/null
}

log_show_tail() {
    local n="${1:-30}"
    if [[ -f "$PORTFW_LOG_FILE" ]]; then
        tail -n "$n" "$PORTFW_LOG_FILE"
    else
        echo "Журнал пока пуст: $PORTFW_LOG_FILE"
    fi
}
