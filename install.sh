#!/usr/bin/env bash
# ==============================================================================
# install.sh - установка Port Forward Manager в систему
# ==============================================================================
set -euo pipefail

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Запустите установку от root: sudo ./install.sh"
    exit 1
fi

TARGET_DIR="/opt/portfw"
BIN_LINK="/usr/local/bin/portfw"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

echo "Проверка зависимостей..."
MISSING=()
for cmd in ip sysctl; do
    command -v "$cmd" &>/dev/null || MISSING+=("$cmd")
done
if ! command -v nft &>/dev/null && ! command -v iptables &>/dev/null; then
    MISSING+=("nftables или iptables")
fi
if (( ${#MISSING[@]} > 0 )); then
    echo "Отсутствуют зависимости: ${MISSING[*]}"
    echo "Установите: apt update && apt install -y iproute2 procps iptables nftables wireguard-tools netcat-openbsd curl iputils-ping"
    exit 1
fi

echo "Копирование файлов в ${TARGET_DIR}..."
mkdir -p "$TARGET_DIR"
cp -r "${SCRIPT_DIR}/lib" "$TARGET_DIR/"
cp "${SCRIPT_DIR}/portfw.sh" "$TARGET_DIR/"
chmod +x "${TARGET_DIR}/portfw.sh"

echo "Создание симлинка ${BIN_LINK}..."
ln -sf "${TARGET_DIR}/portfw.sh" "$BIN_LINK"

mkdir -p /var/backups/portfw
touch /var/log/portfw.log
chmod 640 /var/log/portfw.log

echo
echo "Готово. Запуск: sudo portfw"
echo "Рекомендуемые пакеты для полной функциональности:"
echo "  apt install -y wireguard-tools netcat-openbsd curl iputils-ping iptables-persistent"
