#!/usr/bin/env bash
# ==============================================================================
# colors.sh - ANSI-цвета и функции статусного вывода для Port Forward Manager
# ==============================================================================
# Подключается через: source lib/colors.sh
# Зависимостей нет (чистый bash, работает в любом терминале с поддержкой ANSI).

# Отключаем цвета, если вывод идёт не в терминал (например, в файл/пайп) или
# если задана переменная окружения NO_COLOR.
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RED=$'\033[0;31m'
    C_GREEN=$'\033[0;32m'
    C_YELLOW=$'\033[0;33m'
    C_BLUE=$'\033[0;34m'
    C_CYAN=$'\033[0;36m'
    C_MAGENTA=$'\033[0;35m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_RESET=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_MAGENTA=""
    C_BOLD=""; C_DIM=""; C_RESET=""
fi

# msg_ok "текст"      -> [OK] текст (зелёный)
msg_ok()      { printf '%s[OK]%s      %s\n'      "$C_GREEN"  "$C_RESET" "$*"; }
# msg_info "текст"    -> [INFO] текст (синий)
msg_info()    { printf '%s[INFO]%s    %s\n'      "$C_BLUE"   "$C_RESET" "$*"; }
# msg_warn "текст"    -> [WARNING] текст (жёлтый)
msg_warn()    { printf '%s[WARNING]%s %s\n'      "$C_YELLOW" "$C_RESET" "$*"; }
# msg_err "текст"     -> [ERROR] текст (красный), в stderr
msg_err()     { printf '%s[ERROR]%s   %s\n'      "$C_RED"    "$C_RESET" "$*" >&2; }
# msg_title "текст"   -> заголовок жирным
msg_title()   { printf '%s%s%s\n' "$C_BOLD" "$*" "$C_RESET"; }

# Разделитель для меню
hr() { printf '%s\n' "===================================="; }

# Пауза "нажмите Enter для продолжения"
pause() {
    printf '\n%sНажмите Enter для продолжения...%s' "$C_DIM" "$C_RESET"
    read -r _
}

# Запрос подтверждения Y/N. Возвращает 0 при "да", 1 при "нет".
confirm() {
    local prompt="${1:-Продолжить?}"
    local answer
    read -r -p "$prompt [Y/N]: " answer
    case "$answer" in
        [Yy]|[Yy][Ee][Ss]) return 0 ;;
        *) return 1 ;;
    esac
}
