#!/usr/bin/env bash
# ==============================================================================
# utils.sh - вспомогательные функции: определение интерфейсов, валидация ввода
# ==============================================================================
# Зависимости: iproute2 (ip), coreutils, getent (glibc)

require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        msg_err "Утилита должна запускаться от root (нужны права на iptables/nft/sysctl)."
        exit 1
    fi
}

# --- Валидация -----------------------------------------------------------

is_valid_ipv4() {
    local ip="$1"
    local IFS='.'
    local -a parts
    read -r -a parts <<< "$ip"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local p
    for p in "${parts[@]}"; do
        (( p >= 0 && p <= 255 )) || return 1
    done
    return 0
}

# Проверка одиночного порта 1-65535
is_valid_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]{1,5}$ ]] || return 1
    (( p >= 1 && p <= 65535 ))
}

# Проверка порта или диапазона вида "8080" или "5000-5100"
is_valid_port_or_range() {
    local val="$1"
    if [[ "$val" =~ ^[0-9]{1,5}$ ]]; then
        is_valid_port "$val"
        return $?
    elif [[ "$val" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]]; then
        local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}"
        is_valid_port "$a" && is_valid_port "$b" && (( a < b ))
        return $?
    fi
    return 1
}

# Размер диапазона (1 для одиночного порта)
port_range_size() {
    local val="$1"
    if [[ "$val" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]]; then
        echo $(( ${BASH_REMATCH[2]} - ${BASH_REMATCH[1]} + 1 ))
    else
        echo 1
    fi
}

# Конвертация "5000-5100" -> "5000:5100" (для iptables --dport)
port_range_to_colon() {
    echo "${1//-/:}"
}

is_valid_proto() {
    case "$1" in
        tcp|udp|both) return 0 ;;
        *) return 1 ;;
    esac
}

# --- Определение интерфейсов ---------------------------------------------

# Внешний интерфейс с маршрутом по умолчанию (default route)
get_default_iface() {
    ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | head -n1
}

# Внешний (публичный) IP-адрес на дефолтном интерфейсе (первый IPv4)
get_default_ip() {
    local iface
    iface="$(get_default_iface)"
    [[ -z "$iface" ]] && return 1
    ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet /{print $2}' | head -n1 | cut -d/ -f1
}

# Интерфейс, через который маршрутизируется конкретный IP
# Пример: get_route_iface 10.6.66.20 -> wg0
get_route_iface() {
    local ip="$1"
    ip route get "$ip" 2>/dev/null | grep -oP '(?<=dev )\S+' | head -n1
}

# CIDR-подсеть интерфейса (например wg0 -> 10.6.66.1/24)
get_iface_cidr() {
    local iface="$1"
    ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet /{print $2}' | head -n1
}

iface_exists() {
    ip link show "$1" &>/dev/null
}

iface_is_up() {
    ip link show "$1" 2>/dev/null | grep -q "state UP"
}

# --- Определение имени сервиса по порту -----------------------------------

service_name_for_port() {
    local port="$1" proto="${2:-tcp}"
    local name=""
    if command -v getent &>/dev/null; then
        name="$(getent services "$port/$proto" 2>/dev/null | awk '{print $1}')"
    fi
    if [[ -z "$name" && -r /etc/services ]]; then
        name="$(awk -v p="$port/$proto" '$2==p{print $1; exit}' /etc/services)"
    fi
    # Частые кейсы, которых может не быть в /etc/services
    if [[ -z "$name" ]]; then
        case "$port" in
            25565) name="minecraft" ;;
            51820) name="wireguard" ;;
            3389)  name="rdp" ;;
            8080)  name="http-alt" ;;
            27015) name="steam/source-engine" ;;
        esac
    fi
    echo "${name:-неизвестно}"
}

# Форматирование порта/диапазона с человекочитаемым названием
describe_port() {
    local val="$1" proto="$2"
    if [[ "$val" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        echo "$val (диапазон)"
    else
        echo "$val ($(service_name_for_port "$val" "$proto"))"
    fi
}
