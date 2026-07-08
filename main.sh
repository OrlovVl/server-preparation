#!/bin/bash
set -o pipefail
set -e

# --- Проверка прав root ---
if [ "$EUID" -ne 0 ]; then
    echo "[×] Запускайте от root."
    exit 1
fi

trap 'echo ""; echo "[!] Прервано. Выход."; exit 1' INT TERM

# --- Базовые URL ---
REPO_BASE="https://raw.githubusercontent.com/OrlovVl/server-preparation/refs/heads/main"
SCRIPTS_BASE="${REPO_BASE}/scripts"
ROLLBACK_BASE="${REPO_BASE}/rollback"

# --- Чтение активного профиля ---
get_active_profile() {
    if [[ -f "/opt/remnanode/.profile" ]]; then
        cat "/opt/remnanode/.profile"
    else
        echo "none"
    fi
}

# --- Функция вывода заголовка ---
print_header() {
    clear
    local profile=$(get_active_profile)
    echo "================================================================================"
    echo "                    МАСТЕР-СКРИПТ НАСТРОЙКИ СЕРВЕРА"
    echo "                       Активный профиль: $profile"
    echo "================================================================================"
    local profile=$(get_active_profile)
    echo "  Активный профиль: $profile"
    echo ""
}

# --- Функция выполнения скрипта с GitHub ---
run_script() {
    local url="$1"
    shift
    local args="$@"
    echo "[*] Загружаем и выполняем: $url"
    local ret=0
    if [ -z "$args" ]; then
        curl -fsSL --retry 5 --retry-delay 10 "$url" | bash || ret=$?
    else
        eval "curl -fsSL --retry 5 --retry-delay 10 \"$url\" | bash -s -- $args" || ret=$?
    fi
    if [ $ret -eq 0 ]; then
        echo "[✓] Выполнение завершено успешно."
    else
        echo "[×] Ошибка при выполнении (код $ret). Проверьте логи."
    fi
    return 0
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

ask_domain() {
    read -p "Введите домен для сертификата (например, example.com): " domain
    echo "$domain"
}

ask_email() {
    local domain="$1"
    read -p "Введите email для Let's Encrypt (оставьте пустым для admin@$domain): " email
    [[ -z "$email" ]] && echo "admin@$domain" || echo "$email"
}

# --- КОМПЛЕКСНЫЕ НАСТРОЙКИ ---

# 1. TCP (без заглушки)
full_setup_tcp() {
    echo "[*] Комплексная настройка: обновление + нода + TCP-оптимизация"
    local secret=$(ask_secret_key)
    local tcp_ports=$(ask_tcp_ports)
    run_script "${SCRIPTS_BASE}/init-server.sh"
    run_script "${SCRIPTS_BASE}/setup-node.sh" "--secret-key $secret"
    if [ -n "$tcp_ports" ]; then
        run_script "${SCRIPTS_BASE}/setup-tcp.sh" "--tcp-ports $tcp_ports"
    else
        run_script "${SCRIPTS_BASE}/setup-tcp.sh"
    fi
    echo ""
    echo "[✓] Комплексная настройка TCP завершена."
    echo "Для отката используйте пункт меню 5."
    echo "Для удаления ноды используйте пункт 19."
    read -p "Нажмите Enter для продолжения..."
}

# 2. TCP/UDP (без заглушки)
full_setup_tcp_udp() {
    echo "[*] Комплексная настройка: обновление + нода + TCP/UDP-оптимизация"
    local secret=$(ask_secret_key)
    local tcp_ports=$(ask_tcp_ports)
    local udp_ports=$(ask_udp_ports)
    local args=""
    [ -n "$tcp_ports" ] && args="$args --tcp-ports $tcp_ports"
    [ -n "$udp_ports" ] && args="$args --udp-ports $udp_ports"
    run_script "${SCRIPTS_BASE}/init-server.sh"
    run_script "${SCRIPTS_BASE}/setup-node.sh" "--secret-key $secret"
    run_script "${SCRIPTS_BASE}/setup-tcp-udp.sh" "$args"
    echo ""
    echo "[✓] Комплексная настройка TCP/UDP завершена."
    echo "Для отката используйте пункт меню 6."
    echo "Для удаления ноды используйте пункт 19."
    read -p "Нажмите Enter для продолжения..."
}

# 3. TCP + Nginx + acme (заглушка)
full_setup_tcp_nginx() {
    echo "[*] Комплексная настройка: обновление + нода + TCP-оптимизация + Nginx + acme (заглушка)"
    local secret=$(ask_secret_key)
    local tcp_ports=$(ask_tcp_ports)
    local domain=$(ask_domain)
    local email=$(ask_email "$domain")
    run_script "${SCRIPTS_BASE}/init-server.sh"
    run_script "${SCRIPTS_BASE}/setup-node.sh" "--secret-key $secret"
    if [ -n "$tcp_ports" ]; then
        run_script "${SCRIPTS_BASE}/setup-tcp.sh" "--tcp-ports $tcp_ports"
    else
        run_script "${SCRIPTS_BASE}/setup-tcp.sh"
    fi
    run_script "${SCRIPTS_BASE}/setup-nginx-acme.sh" "--domain $domain --email $email"
    echo ""
    echo "[✓] Комплексная настройка TCP + Nginx завершена."
    echo "Для отката используйте пункт меню 7."
    echo "Для удаления ноды используйте пункт 19."
    read -p "Нажмите Enter для продолжения..."
}

# 4. TCP/UDP + Nginx + acme (заглушка)
full_setup_tcp_udp_nginx() {
    echo "[*] Комплексная настройка: обновление + нода + TCP/UDP-оптимизация + Nginx + acme (заглушка)"
    local secret=$(ask_secret_key)
    local tcp_ports=$(ask_tcp_ports)
    local udp_ports=$(ask_udp_ports)
    local domain=$(ask_domain)
    local email=$(ask_email "$domain")
    local args=""
    [ -n "$tcp_ports" ] && args="$args --tcp-ports $tcp_ports"
    [ -n "$udp_ports" ] && args="$args --udp-ports $udp_ports"
    run_script "${SCRIPTS_BASE}/init-server.sh"
    run_script "${SCRIPTS_BASE}/setup-node.sh" "--secret-key $secret"
    run_script "${SCRIPTS_BASE}/setup-tcp-udp.sh" "$args"
    run_script "${SCRIPTS_BASE}/setup-nginx-acme.sh" "--domain $domain --email $email"
    echo ""
    echo "[✓] Комплексная настройка TCP/UDP + Nginx завершена."
    echo "Для отката используйте пункт меню 8."
    echo "Для удаления ноды используйте пункт 19."
    read -p "Нажмите Enter для продолжения..."
}

# --- КОМПЛЕКСНЫЕ ОТКАТЫ (нода не удаляется) ---

rollback_tcp() {
    run_script "${ROLLBACK_BASE}/rollback-tcp.sh"
    read -p "Нажмите Enter для продолжения..."
}

rollback_tcp_udp() {
    run_script "${ROLLBACK_BASE}/rollback-tcp-udp.sh"
    read -p "Нажмите Enter для продолжения..."
}

rollback_tcp_nginx() {
    run_script "${ROLLBACK_BASE}/rollback-tcp.sh"
    run_script "${ROLLBACK_BASE}/rollback-nginx.sh"
    read -p "Нажмите Enter для продолжения..."
}

rollback_tcp_udp_nginx() {
    run_script "${ROLLBACK_BASE}/rollback-tcp-udp.sh"
    run_script "${ROLLBACK_BASE}/rollback-nginx.sh"
    read -p "Нажмите Enter для продолжения..."
}

# --- ОСНОВНОЙ ЦИКЛ ---
while true; do
    print_header
    echo "Выберите действие:"
    echo ""
    echo "  === КОМПЛЕКСНЫЕ НАСТРОЙКИ ==="
    echo "  1. TCP (обновление + нода + TCP-оптимизация)"
    echo "  2. TCP/UDP (обновление + нода + TCP/UDP-оптимизация)"
    echo "  3. TCP + Nginx + acme (заглушка)"
    echo "  4. TCP/UDP + Nginx + acme (заглушка)"
    echo ""
    echo "  === КОМПЛЕКСНЫЕ ОТКАТЫ (нода не удаляется) ==="
    echo "  5. Откат TCP"
    echo "  6. Откат TCP/UDP"
    echo "  7. Откат TCP + Nginx"
    echo "  8. Откат TCP/UDP + Nginx"
    echo ""
    echo "  === ОТДЕЛЬНЫЕ ДЕЙСТВИЯ (УСТАНОВКА/НАСТРОЙКА) ==="
    echo "  9. Базовая подготовка сервера (обновление + Docker)"
    echo " 10. Установка ноды (RemnaNode)"
    echo " 11. Установка кастомного Xray-core"
    echo " 12. Настройка TCP-оптимизации (с доп. портами)"
    echo " 13. Настройка TCP/UDP-оптимизации (с доп. портами)"
    echo " 14. Настройка Nginx + acme (заглушка)"
    echo ""
    echo "  === ОТДЕЛЬНЫЕ ОТКАТЫ ==="
    echo " 15. Откат кастомного Xray-core"
    echo " 16. Откат TCP-оптимизации"
    echo " 17. Откат TCP/UDP-оптимизации"
    echo " 18. Откат Nginx + acme (заглушка)"
    echo " 19. Откат ноды (удаление контейнера и файлов)"
    echo ""
    echo "  === СИСТЕМНЫЕ ==="
    echo " 20. Перезагрузка сервера"
    echo "  0. Выход"
    echo ""
    read -p "Введите номер пункта: " choice

    case $choice in
        1) full_setup_tcp ;;
        2) full_setup_tcp_udp ;;
        3) full_setup_tcp_nginx ;;
        4) full_setup_tcp_udp_nginx ;;
        5) rollback_tcp ;;
        6) rollback_tcp_udp ;;
        7) rollback_tcp_nginx ;;
        8) rollback_tcp_udp_nginx ;;
        9) run_script "${SCRIPTS_BASE}/init-server.sh"; read -p "Нажмите Enter..." ;;
        10) secret=$(ask_secret_key); run_script "${SCRIPTS_BASE}/setup-node.sh" "--secret-key $secret"; read -p "Нажмите Enter..." ;;
        11) version=$(ask_kernel_version); run_script "${SCRIPTS_BASE}/setup-custom-kernel.sh" "--version $version"; read -p "Нажмите Enter..." ;;
        12) tcp_ports=$(ask_tcp_ports); [ -n "$tcp_ports" ] && args="--tcp-ports $tcp_ports" || args=""; run_script "${SCRIPTS_BASE}/setup-tcp.sh" "$args"; read -p "Нажмите Enter..." ;;
        13) tcp_ports=$(ask_tcp_ports); udp_ports=$(ask_udp_ports); args=""; [ -n "$tcp_ports" ] && args="$args --tcp-ports $tcp_ports"; [ -n "$udp_ports" ] && args="$args --udp-ports $udp_ports"; run_script "${SCRIPTS_BASE}/setup-tcp-udp.sh" "$args"; read -p "Нажмите Enter..." ;;
        14) domain=$(ask_domain); email=$(ask_email "$domain"); run_script "${SCRIPTS_BASE}/setup-nginx-acme.sh" "--domain $domain --email $email"; read -p "Нажмите Enter..." ;;
        15) run_script "${ROLLBACK_BASE}/rollback-custom-kernel.sh"; read -p "Нажмите Enter..." ;;
        16) run_script "${ROLLBACK_BASE}/rollback-tcp.sh"; read -p "Нажмите Enter..." ;;
        17) run_script "${ROLLBACK_BASE}/rollback-tcp-udp.sh"; read -p "Нажмите Enter..." ;;
        18) run_script "${ROLLBACK_BASE}/rollback-nginx.sh"; read -p "Нажмите Enter..." ;;
        19) run_script "${ROLLBACK_BASE}/rollback-node.sh"; read -p "Нажмите Enter..." ;;
        20) echo "[*] Перезагрузка сервера..."; reboot ;;
        0) echo "[✓] Выход."; exit 0 ;;
        *) echo "[×] Неверный пункт."; read -p "Нажмите Enter..." ;;
    esac
done
