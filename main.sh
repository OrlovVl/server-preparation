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
        curl -fsSL --retry 5 --retry-delay 10 "$url" | bash -s -- $args || ret=$?
    fi
    if [ $ret -eq 0 ]; then
        echo "[✓] Выполнение завершено успешно."
    else
        echo "[×] Ошибка при выполнении (код $ret). Проверьте логи."
    fi
    return $ret
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

# --- Настройка отправки логов в Telegram ---
setup_telegram_logs() {
    echo "[*] Настройка отправки логов в Telegram"
    local bot_token chat_id send_time prefix
    read -p "Введите Telegram Bot Token: " bot_token
    read -p "Введите Chat ID: " chat_id
    read -p "Введите время отправки (HH:MM, по умолчанию 00:00): " send_time
    [[ -z "$send_time" ]] && send_time="00:00"
    read -p "Введите префикс для логов (оставьте пустым для имени хоста): " prefix
    [[ -z "$prefix" ]] && prefix=$(hostname)
    
    local args="--token $bot_token --chat-id $chat_id --time $send_time --prefix $prefix"
    run_script "${SCRIPTS_BASE}/setup-telegram-logs.sh" "$args" || {
        echo "[×] Ошибка при настройке отправки логов."
        return 1
    }
    return 0
}

rollback_telegram_logs() {
    run_script "${ROLLBACK_BASE}/rollback-telegram-logs.sh" || {
        echo "[×] Ошибка при откате отправки логов."
        return 1
    }
    return 0
}

send_logs_now() {
    if [[ -x "/usr/local/bin/send-xray-logs-now.sh" ]]; then
        /usr/local/bin/send-xray-logs-now.sh
    else
        echo "[!] Скрипт отправки логов не найден. Сначала выполните настройку (пункт 15)."
    fi
}

# --- КОМПЛЕКСНЫЕ НАСТРОЙКИ ---

# 1. TCP (без заглушки)
full_setup_tcp() {
    echo "[*] Комплексная настройка: обновление + нода + TCP-оптимизация + логи"
    local secret=$(ask_secret_key)
    local tcp_ports=$(ask_tcp_ports)
    run_script "${SCRIPTS_BASE}/init-server.sh" || {
        echo "[×] Ошибка на этапе init-server.sh. Прерываем."
        return 1
    }
    run_script "${SCRIPTS_BASE}/setup-node.sh" "--secret-key $secret" || {
        echo "[×] Ошибка на этапе setup-node.sh. Прерываем."
        return 1
    }
    if [ -n "$tcp_ports" ]; then
        run_script "${SCRIPTS_BASE}/setup-tcp.sh" "--tcp-ports $tcp_ports" || {
            echo "[×] Ошибка на этапе setup-tcp.sh. Прерываем."
            return 1
        }
    else
        run_script "${SCRIPTS_BASE}/setup-tcp.sh" || {
            echo "[×] Ошибка на этапе setup-tcp.sh. Прерываем."
            return 1
        }
    fi
    setup_telegram_logs || return 1
    mkdir -p /opt/remnanode
    echo "1. tcp" > /opt/remnanode/.profile
    echo ""
    echo "[✓] Комплексная настройка TCP завершена."
    echo "Для отката используйте пункт меню 5."
    echo "Для удаления ноды используйте пункт 19."
    read -p "Нажмите Enter для продолжения..."
    return 0
}

# 2. TCP/UDP (без заглушки)
full_setup_tcp_udp() {
    echo "[*] Комплексная настройка: обновление + нода + TCP/UDP-оптимизация + логи"
    local secret=$(ask_secret_key)
    local tcp_ports=$(ask_tcp_ports)
    local udp_ports=$(ask_udp_ports)
    local args=""
    [ -n "$tcp_ports" ] && args="$args --tcp-ports $tcp_ports"
    [ -n "$udp_ports" ] && args="$args --udp-ports $udp_ports"
    run_script "${SCRIPTS_BASE}/init-server.sh" || {
        echo "[×] Ошибка на этапе init-server.sh. Прерываем."
        return 1
    }
    run_script "${SCRIPTS_BASE}/setup-node.sh" "--secret-key $secret" || {
        echo "[×] Ошибка на этапе setup-node.sh. Прерываем."
        return 1
    }
    run_script "${SCRIPTS_BASE}/setup-tcp-udp.sh" "$args" || {
        echo "[×] Ошибка на этапе setup-tcp-udp.sh. Прерываем."
        return 1
    }
    setup_telegram_logs || return 1
    mkdir -p /opt/remnanode
    echo "2. tcp-udp" > /opt/remnanode/.profile
    echo ""
    echo "[✓] Комплексная настройка TCP/UDP завершена."
    echo "Для отката используйте пункт меню 6."
    echo "Для удаления ноды используйте пункт 19."
    read -p "Нажмите Enter для продолжения..."
    return 0
}

# 3. TCP + Nginx + acme (заглушка)
full_setup_tcp_nginx() {
    echo "[*] Комплексная настройка: обновление + нода + TCP-оптимизация + Nginx + acme + заглушка + логи"
    local secret=$(ask_secret_key)
    local tcp_ports=$(ask_tcp_ports)
    local domain=$(ask_domain)
    local email=$(ask_email "$domain")
    run_script "${SCRIPTS_BASE}/init-server.sh" || {
        echo "[×] Ошибка на этапе init-server.sh. Прерываем."
        return 1
    }
    run_script "${SCRIPTS_BASE}/setup-node.sh" "--secret-key $secret" || {
        echo "[×] Ошибка на этапе setup-node.sh. Прерываем."
        return 1
    }
    if [ -n "$tcp_ports" ]; then
        run_script "${SCRIPTS_BASE}/setup-tcp.sh" "--tcp-ports $tcp_ports" || {
            echo "[×] Ошибка на этапе setup-tcp.sh. Прерываем."
            return 1
        }
    else
        run_script "${SCRIPTS_BASE}/setup-tcp.sh" || {
            echo "[×] Ошибка на этапе setup-tcp.sh. Прерываем."
            return 1
        }
    fi
    run_script "${SCRIPTS_BASE}/setup-nginx-acme-filecloud.sh" "--domain $domain --email $email" || {
        echo "[×] Ошибка на этапе setup-nginx-acme-filecloud.sh. Прерываем."
        return 1
    }
    setup_telegram_logs || return 1
    mkdir -p /opt/remnanode
    echo "3. tcp-nginx-cert" > /opt/remnanode/.profile
    echo ""
    echo "[✓] Комплексная настройка TCP + Nginx завершена."
    echo "Для отката используйте пункт меню 7."
    echo "Для удаления ноды используйте пункт 19."
    read -p "Нажмите Enter для продолжения..."
    return 0
}

# 4. TCP/UDP + Nginx + acme (заглушка)
full_setup_tcp_udp_nginx() {
    echo "[*] Комплексная настройка: обновление + нода + TCP/UDP-оптимизация + Nginx + acme + заглушка + логи"
    local secret=$(ask_secret_key)
    local tcp_ports=$(ask_tcp_ports)
    local udp_ports=$(ask_udp_ports)
    local domain=$(ask_domain)
    local email=$(ask_email "$domain")
    local args=""
    [ -n "$tcp_ports" ] && args="$args --tcp-ports $tcp_ports"
    [ -n "$udp_ports" ] && args="$args --udp-ports $udp_ports"
    run_script "${SCRIPTS_BASE}/init-server.sh" || {
        echo "[×] Ошибка на этапе init-server.sh. Прерываем."
        return 1
    }
    run_script "${SCRIPTS_BASE}/setup-node.sh" "--secret-key $secret" || {
        echo "[×] Ошибка на этапе setup-node.sh. Прерываем."
        return 1
    }
    run_script "${SCRIPTS_BASE}/setup-tcp-udp.sh" "$args" || {
        echo "[×] Ошибка на этапе setup-tcp-udp.sh. Прерываем."
        return 1
    }
    run_script "${SCRIPTS_BASE}/setup-nginx-acme-filecloud.sh" "--domain $domain --email $email" || {
        echo "[×] Ошибка на этапе setup-nginx-acme-filecloud.sh. Прерываем."
        return 1
    }
    setup_telegram_logs || return 1
    mkdir -p /opt/remnanode
    echo "4. tcp-udp-nginx-cert" > /opt/remnanode/.profile
    echo ""
    echo "[✓] Комплексная настройка TCP/UDP + Nginx завершена."
    echo "Для отката используйте пункт меню 8."
    echo "Для удаления ноды используйте пункт 19."
    read -p "Нажмите Enter для продолжения..."
    return 0
}

# --- КОМПЛЕКСНЫЕ ОТКАТЫ (нода не удаляется) ---

rollback_tcp() {
    run_script "${ROLLBACK_BASE}/rollback-tcp.sh" || { 
        echo "[×] Ошибка при откате TCP. Прерываем."
        return 1
    }
    rollback_telegram_logs || echo "[!] Ошибка при откате логов."
    if [[ -f "/opt/remnanode/.profile" ]] && grep -q "1. tcp" "/opt/remnanode/.profile"; then
        rm -f "/opt/remnanode/.profile"
        echo "[✓] Маркер профиля удалён."
    fi
    read -p "Нажмите Enter для продолжения..."
    return 0
}

rollback_tcp_udp() {
    run_script "${ROLLBACK_BASE}/rollback-tcp-udp.sh" || {
        echo "[×] Ошибка при откате TCP/UDP. Прерываем."
        return 1
    }
    rollback_telegram_logs || echo "[!] Ошибка при откате логов."
    if [[ -f "/opt/remnanode/.profile" ]] && grep -q "2. tcp-udp" "/opt/remnanode/.profile"; then
        rm -f "/opt/remnanode/.profile"
        echo "[✓] Маркер профиля удалён."
    fi
    read -p "Нажмите Enter для продолжения..."
    return 0
}

rollback_tcp_nginx() {
    run_script "${ROLLBACK_BASE}/rollback-tcp.sh" || {
        echo "[×] Ошибка при откате TCP (часть отката TCP+Nginx). Прерываем."
        return 1
    }
    run_script "${ROLLBACK_BASE}/rollback-nginx-acme-filecloud.sh" || {
        echo "[×] Ошибка при откате Nginx+acme (часть отката TCP+Nginx). Прерываем."
        return 1
    }
    rollback_telegram_logs || echo "[!] Ошибка при откате логов."
    if [[ -f "/opt/remnanode/.profile" ]] && grep -q "3. tcp-nginx-cert" "/opt/remnanode/.profile"; then
        rm -f "/opt/remnanode/.profile"
        echo "[✓] Маркер профиля удалён."
    fi
    read -p "Нажмите Enter для продолжения..."
    return 0
}

rollback_tcp_udp_nginx() {
    run_script "${ROLLBACK_BASE}/rollback-tcp-udp.sh" || {
        echo "[×] Ошибка при откате TCP/UDP (часть отката TCP/UDP+Nginx). Прерываем."
        return 1
    }
    run_script "${ROLLBACK_BASE}/rollback-nginx-acme-filecloud.sh" || {
        echo "[×] Ошибка при откате Nginx+acme (часть отката TCP/UDP+Nginx). Прерываем."
        return 1
    }
    rollback_telegram_logs || echo "[!] Ошибка при откате логов."
    if [[ -f "/opt/remnanode/.profile" ]] && grep -q "4. tcp-udp-nginx-cert" "/opt/remnanode/.profile"; then
        rm -f "/opt/remnanode/.profile"
        echo "[✓] Маркер профиля удалён."
    fi
    read -p "Нажмите Enter для продолжения..."
    return 0
}

# --- ОСНОВНОЙ ЦИКЛ ---
while true; do
    print_header
    echo "Выберите действие:"
    echo ""
    echo "  === КОМПЛЕКСНЫЕ НАСТРОЙКИ ==="
    echo "  1. TCP (обновление + нода + TCP-оптимизация + логи)"
    echo "  2. TCP/UDP (обновление + нода + TCP/UDP-оптимизация + логи)"
    echo "  3. TCP + Nginx + acme + заглушка + логи"
    echo "  4. TCP/UDP + Nginx + acme + заглушка + логи"
    echo ""
    echo "  === КОМПЛЕКСНЫЕ ОТКАТЫ (нода не удаляется) ==="
    echo "  5. Откат TCP + логи"
    echo "  6. Откат TCP/UDP + логи"
    echo "  7. Откат TCP + Nginx + логи"
    echo "  8. Откат TCP/UDP + Nginx + логи"
    echo ""
    echo "  === ОТДЕЛЬНЫЕ ДЕЙСТВИЯ (УСТАНОВКА/НАСТРОЙКА) ==="
    echo "  9. Базовая подготовка сервера (обновление + Docker)"
    echo " 10. Установка ноды (RemnaNode)"
    echo " 11. Установка кастомного Xray-core"
    echo " 12. Настройка TCP-оптимизации (с доп. портами)"
    echo " 13. Настройка TCP/UDP-оптимизации (с доп. портами)"
    echo " 14. Настройка Nginx + acme (заглушка)"
    echo " 15. Настройка отправки логов Xray в Telegram (ежедневно)"
    echo " 16. Отправить логи сейчас (без очистки)"
    echo ""
    echo "  === ОТДЕЛЬНЫЕ ОТКАТЫ ==="
    echo " 17. Откат кастомного Xray-core"
    echo " 18. Откат TCP-оптимизации"
    echo " 19. Откат TCP/UDP-оптимизации"
    echo " 20. Откат Nginx + acme (заглушка)"
    echo " 21. Откат отправки логов"
    echo " 22. Откат ноды (удаление контейнера и файлов)"
    echo ""
    echo "  === СИСТЕМНЫЕ ==="
    echo " 23. Перезагрузка сервера"
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
        9) run_script "${SCRIPTS_BASE}/init-server.sh" || echo "[×] Ошибка при выполнении init-server.sh."; read -p "Нажмите Enter..." ;;
        10) secret=$(ask_secret_key); run_script "${SCRIPTS_BASE}/setup-node.sh" "--secret-key $secret" || echo "[×] Ошибка при установке ноды."; read -p "Нажмите Enter..." ;;
        11) version=$(ask_kernel_version); run_script "${SCRIPTS_BASE}/setup-custom-kernel.sh" "--version $version" || echo "[×] Ошибка при установке кастомного Xray-core."; read -p "Нажмите Enter..." ;;
        12) tcp_ports=$(ask_tcp_ports); [ -n "$tcp_ports" ] && args="--tcp-ports $tcp_ports" || args=""; run_script "${SCRIPTS_BASE}/setup-tcp.sh" "$args" || echo "[×] Ошибка при настройке TCP."; read -p "Нажмите Enter..." ;;
        13) tcp_ports=$(ask_tcp_ports); udp_ports=$(ask_udp_ports); args=""; [ -n "$tcp_ports" ] && args="$args --tcp-ports $tcp_ports"; [ -n "$udp_ports" ] && args="$args --udp-ports $udp_ports"; run_script "${SCRIPTS_BASE}/setup-tcp-udp.sh" "$args" || echo "[×] Ошибка при настройке TCP/UDP."; read -p "Нажмите Enter..." ;;
        14) domain=$(ask_domain); email=$(ask_email "$domain"); run_script "${SCRIPTS_BASE}/setup-nginx-acme-filecloud.sh" "--domain $domain --email $email" || echo "[×] Ошибка при настройке Nginx+acme."; read -p "Нажмите Enter..." ;;
        15) setup_telegram_logs; read -p "Нажмите Enter..." ;;
        16) send_logs_now; read -p "Нажмите Enter..." ;;
        17) run_script "${ROLLBACK_BASE}/rollback-custom-kernel.sh" || echo "[×] Ошибка при откате кастомного Xray-core."; read -p "Нажмите Enter..." ;;
        18) run_script "${ROLLBACK_BASE}/rollback-tcp.sh" || echo "[×] Ошибка при откате TCP."; read -p "Нажмите Enter..." ;;
        19) run_script "${ROLLBACK_BASE}/rollback-tcp-udp.sh" || echo "[×] Ошибка при откате TCP/UDP."; read -p "Нажмите Enter..." ;;
        20) run_script "${ROLLBACK_BASE}/rollback-nginx-acme-filecloud.sh" || echo "[×] Ошибка при откате Nginx+acme."; read -p "Нажмите Enter..." ;;
        21) rollback_telegram_logs; read -p "Нажмите Enter..." ;;
        22) run_script "${ROLLBACK_BASE}/rollback-node.sh" || echo "[×] Ошибка при откате ноды."; read -p "Нажмите Enter..." ;;
        23) echo "[*] Перезагрузка сервера..."; reboot ;;
        0) echo "[✓] Выход."; exit 0 ;;
        *) echo "[×] Неверный пункт."; read -p "Нажмите Enter..." ;;
    esac
done
