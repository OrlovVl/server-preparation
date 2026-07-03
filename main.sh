#!/bin/bash

set -o pipefail
set -e

# --- Проверка прав root ---
if [ "$EUID" -ne 0 ]; then
    echo "[×] Запускайте от root."
    exit 1
fi

# --- Базовые URL ---
REPO_BASE="https://raw.githubusercontent.com/OrlovVl/server-preparation/refs/heads/main"
SCRIPTS_BASE="${REPO_BASE}/scripts"
ROLLBACK_BASE="${REPO_BASE}/rollback"

# --- Функция вывода заголовка ---
print_header() {
    clear
    echo "================================================================================"
    echo "                    МАСТЕР-СКРИПТ НАСТРОЙКИ СЕРВЕРА"
    echo "================================================================================"
    echo ""
}

# --- Функция выполнения скрипта с GitHub ---
run_script() {
    local url="$1"
    shift
    local args="$@"
    echo "[*] Загружаем и выполняем: $url"
    if [ -z "$args" ]; then
        curl -fsSL "$url" | bash
    else
        curl -fsSL "$url" | bash -s -- $args
    fi
    if [ $? -eq 0 ]; then
        echo "[✓] Выполнение завершено успешно."
    else
        echo "[×] Ошибка при выполнении. Проверьте логи."
    fi
}

# --- Функции запроса параметров ---
ask_secret_key() {
    read -p "Введите SECRET_KEY для ноды: " secret
    echo "$secret"
}

ask_kernel_version() {
    read -p "Введите версию Xray-core (например, 26.6.27): " version
    echo "$version"
}

ask_tcp_ports() {
    read -p "Введите дополнительные TCP-порты через запятую (например, 8080,8443) или оставьте пустым: " ports
    echo "$ports"
}

ask_udp_ports() {
    read -p "Введите дополнительные UDP-порты через запятую (например, 53,123) или оставьте пустым: " ports
    echo "$ports"
}

ask_caddy_params() {
    read -p "Введите домен (например, example.com): " domain
    read -p "Введите Porkbun API Key: " api_key
    read -p "Введите Porkbun Secret Key: " secret
    echo "--domain $domain --porkbun-api-key $api_key --porkbun-secret $secret"
}

# --- Комплексная настройка (пункт 1) ---
full_setup_tcp() {
    echo "[*] Комплексная настройка: обновление + нода + TCP-оптимизация"
    run_script "${SCRIPTS_BASE}/init-server.sh"
    secret=$(ask_secret_key)
    run_script "${SCRIPTS_BASE}/setup-node.sh" "--secret-key $secret"
    tcp_ports=$(ask_tcp_ports)
    if [ -n "$tcp_ports" ]; then
        run_script "${SCRIPTS_BASE}/setup-tcp.sh" "--tcp-ports $tcp_ports"
    else
        run_script "${SCRIPTS_BASE}/setup-tcp.sh"
    fi
    echo ""
    echo "[✓] Комплексная настройка TCP завершена."
    echo "Для отката TCP-оптимизации используйте пункт меню 3."
    echo "Для удаления ноды используйте пункт меню 15."
    read -p "Нажмите Enter для продолжения..."
}

# --- Комплексная настройка (пункт 2) ---
full_setup_tcp_udp() {
    echo "[*] Комплексная настройка: обновление + нода + TCP/UDP-оптимизация + Caddy"
    run_script "${SCRIPTS_BASE}/init-server.sh"
    secret=$(ask_secret_key)
    run_script "${SCRIPTS_BASE}/setup-node.sh" "--secret-key $secret"
    tcp_ports=$(ask_tcp_ports)
    udp_ports=$(ask_udp_ports)
    args=""
    [ -n "$tcp_ports" ] && args="$args --tcp-ports $tcp_ports"
    [ -n "$udp_ports" ] && args="$args --udp-ports $udp_ports"
    run_script "${SCRIPTS_BASE}/setup-tcp-udp.sh" "$args"
    caddy_args=$(ask_caddy_params)
    run_script "${SCRIPTS_BASE}/setup-caddy-filecloud.sh" "$caddy_args"
    echo ""
    echo "[✓] Комплексная настройка TCP/UDP завершена."
    echo "Для отката Caddy и TCP/UDP-оптимизации используйте пункт меню 4."
    echo "Для удаления ноды используйте пункт меню 15."
    read -p "Нажмите Enter для продолжения..."
}

# --- Комплексный откат TCP (пункт 3) — только TCP, не трогаем ноду ---
rollback_full_tcp() {
    echo "[*] Комплексный откат TCP: откатываем TCP-оптимизацию (нода остаётся)"
    echo "Выполняется откат TCP..."
    run_script "${ROLLBACK_BASE}/rollback-tcp.sh"
    echo ""
    echo "[✓] Комплексный откат TCP завершён."
    echo "Нода не была удалена. При необходимости удалите ноду через пункт меню 15."
    echo "init-server.sh не откатывается, система остаётся обновлённой."
    read -p "Нажмите Enter для продолжения..."
}

# --- Комплексный откат TCP/UDP (пункт 4) — откатываем Caddy и TCP/UDP, ноду не трогаем ---
rollback_full_tcp_udp() {
    echo "[*] Комплексный откат TCP/UDP: откатываем Caddy и TCP/UDP-оптимизацию (нода остаётся)"
    echo "Выполняется откат Caddy+FileCloud..."
    run_script "${ROLLBACK_BASE}/rollback-caddy-filecloud.sh"
    echo "Выполняется откат TCP/UDP-оптимизации..."
    run_script "${ROLLBACK_BASE}/rollback-tcp-udp.sh"
    echo ""
    echo "[✓] Комплексный откат TCP/UDP завершён."
    echo "Нода не была удалена. При необходимости удалите ноду через пункт меню 15."
    echo "init-server.sh не откатывается, система остаётся обновлённой."
    read -p "Нажмите Enter для продолжения..."
}

# --- Основной цикл ---
while true; do
    print_header
    echo "Выберите действие:"
    echo ""
    echo "  === КОМПЛЕКСНЫЕ НАСТРОЙКИ ==="
    echo "  1. Полная настройка под TCP (обновление + нода + TCP-оптимизация)"
    echo "  2. Полная настройка под TCP/UDP (обновление + нода + TCP/UDP + Caddy)"
    echo ""
    echo "  === КОМПЛЕКСНЫЕ ОТКАТЫ (нода не удаляется) ==="
    echo "  3. Откат TCP-оптимизации (нода остаётся)"
    echo "  4. Откат Caddy + TCP/UDP-оптимизации (нода остаётся)"
    echo ""
    echo "  === ОТДЕЛЬНЫЕ ДЕЙСТВИЯ (УСТАНОВКА/НАСТРОЙКА) ==="
    echo "  5. Базовая подготовка сервера (обновление + Docker)"
    echo "  6. Установка ноды (RemnaNode)"
    echo "  7. Установка кастомного Xray-core"
    echo "  8. Настройка TCP-оптимизации (с доп. портами)"
    echo "  9. Настройка TCP/UDP-оптимизации (с доп. портами)"
    echo " 10. Настройка Caddy + FileCloud (сертификаты Porkbun)"
    echo ""
    echo "  === ОТДЕЛЬНЫЕ ОТКАТЫ ==="
    echo " 11. Откат кастомного Xray-core"
    echo " 12. Откат TCP-оптимизации"
    echo " 13. Откат TCP/UDP-оптимизации"
    echo " 14. Откат Caddy + FileCloud"
    echo " 15. Откат ноды (удаление контейнера и файлов)"
    echo ""
    echo "  === СИСТЕМНЫЕ ==="
    echo " 16. Перезагрузка сервера"
    echo "  0. Выход"
    echo ""
    read -p "Введите номер пункта: " choice

    case $choice in
        1) full_setup_tcp ;;
        2) full_setup_tcp_udp ;;
        3) rollback_full_tcp ;;
        4) rollback_full_tcp_udp ;;
        5) run_script "${SCRIPTS_BASE}/init-server.sh"; read -p "Нажмите Enter..." ;;
        6) secret=$(ask_secret_key); run_script "${SCRIPTS_BASE}/setup-node.sh" "--secret-key $secret"; read -p "Нажмите Enter..." ;;
        7) version=$(ask_kernel_version); run_script "${SCRIPTS_BASE}/setup-custom-kernel.sh" "--version $version"; read -p "Нажмите Enter..." ;;
        8) tcp_ports=$(ask_tcp_ports); [ -n "$tcp_ports" ] && args="--tcp-ports $tcp_ports" || args=""; run_script "${SCRIPTS_BASE}/setup-tcp.sh" "$args"; read -p "Нажмите Enter..." ;;
        9) tcp_ports=$(ask_tcp_ports); udp_ports=$(ask_udp_ports); args=""; [ -n "$tcp_ports" ] && args="$args --tcp-ports $tcp_ports"; [ -n "$udp_ports" ] && args="$args --udp-ports $udp_ports"; run_script "${SCRIPTS_BASE}/setup-tcp-udp.sh" "$args"; read -p "Нажмите Enter..." ;;
        10) caddy_args=$(ask_caddy_params); run_script "${SCRIPTS_BASE}/setup-caddy-filecloud.sh" "$caddy_args"; read -p "Нажмите Enter..." ;;
        11) run_script "${ROLLBACK_BASE}/rollback-custom-kernel.sh"; read -p "Нажмите Enter..." ;;
        12) run_script "${ROLLBACK_BASE}/rollback-tcp.sh"; read -p "Нажмите Enter..." ;;
        13) run_script "${ROLLBACK_BASE}/rollback-tcp-udp.sh"; read -p "Нажмите Enter..." ;;
        14) run_script "${ROLLBACK_BASE}/rollback-caddy-filecloud.sh"; read -p "Нажмите Enter..." ;;
        15) run_script "${ROLLBACK_BASE}/rollback-node.sh"; read -p "Нажмите Enter..." ;;
        16) echo "[*] Перезагрузка сервера..."; reboot ;;
        0) echo "[✓] Выход."; exit 0 ;;
        *) echo "[×] Неверный пункт."; read -p "Нажмите Enter..." ;;
    esac
done
