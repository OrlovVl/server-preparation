#!/bin/bash
set -o pipefail
set -e

if [ "$EUID" -ne 0 ]; then
    echo "[×] Запускайте от root."
    exit 1
fi

# --- Проверка Docker ---
if ! command -v docker &> /dev/null; then
    echo "[!] Docker не установлен."
    exit 1
fi

# --- Определение команды docker compose ---
if docker compose version &> /dev/null; then
    DOCKER_COMPOSE="docker compose"
elif command -v docker-compose &> /dev/null; then
    DOCKER_COMPOSE="docker-compose"
else
    echo "[!] docker compose (или docker-compose) не установлен. Установите отдельно."
    exit 1
fi

echo "[*] Откат Nginx + acme + FileCloud..."

# --- 1. Останавливаем и отключаем Nginx ---
systemctl stop nginx 2>/dev/null || true
systemctl disable nginx 2>/dev/null || true

# --- 2. Удаляем конфиги Nginx ---
rm -f /etc/nginx/sites-enabled/filecloud
rm -f /etc/nginx/sites-available/filecloud
rm -f /etc/nginx/.htpasswd

# --- 3. Удаляем папку заглушки ---
if [[ -d "/opt/remnanode/filecloud" ]]; then
    rm -rf /opt/remnanode/filecloud
    echo "[✓] Папка заглушки удалена."
fi

# --- 4. Удаляем acme.sh ---
if [[ -x /root/.acme.sh/acme.sh ]]; then
    echo "[*] Удаляем acme.sh..."
    # Деинсталляция через встроенную команду
    /root/.acme.sh/acme.sh --uninstall || true
    rm -rf /root/.acme.sh
    echo "[✓] acme.sh удалён."
fi

# --- 5. Удаляем сертификаты ---
if [[ -d "/etc/node-certs" ]]; then
    rm -rf /etc/node-certs
    echo "[✓] Сертификаты удалены (/etc/node-certs)."
fi
if [[ -d "/etc/remna-certs" ]]; then
    rm -rf /etc/remna-certs
    echo "[✓] Сертификаты удалены (/etc/remna-certs)."
fi

# --- 6. Удаление симлинков сертификатов ---
if [[ -L "/etc/ssl/certs/noctua.crt" ]]; then
    rm -f /etc/ssl/certs/noctua.crt
    echo "[✓] Симлинк /etc/ssl/certs/noctua.crt удалён."
fi
if [[ -L "/etc/ssl/private/noctua.key" ]]; then
    rm -f /etc/ssl/private/noctua.key
    echo "[✓] Симлинк /etc/ssl/private/noctua.key удалён."
fi

# --- 7. Удаляем монтирование сертификатов из docker-compose.yml ---
COMPOSE_FILE="/opt/remnanode/docker-compose.yml"
if [[ -f "$COMPOSE_FILE" ]]; then
    echo "[*] Проверяем монтирование сертификатов в remnanode..."
    if grep -q "/etc/ssl/certs/noctua.crt" "$COMPOSE_FILE" || grep -q "/etc/ssl/private/noctua.key" "$COMPOSE_FILE"; then
        cp "$COMPOSE_FILE" "$COMPOSE_FILE.bak"
        echo "[*] Удаляем строки монтирования..."
        sed -i "\|/etc/ssl/certs/noctua.crt|d" "$COMPOSE_FILE"
        sed -i "\|/etc/ssl/private/noctua.key|d" "$COMPOSE_FILE"
        echo "[✓] Строки монтирования удалены."

        # Проверяем, пуста ли секция volumes
        if grep -q "^    volumes:" "$COMPOSE_FILE"; then
            # Проверяем наличие других монтирований в секции
            if ! awk '/^    volumes:/,/^  / { if ($0 ~ /^      - /) found=1 } END { exit !found }' "$COMPOSE_FILE"; then
                sed -i '/^    volumes:/,/^  /d' "$COMPOSE_FILE"
                echo "[✓] Секция volumes была пустой и удалена."
            else
                echo "[✓] Секция volumes содержит другие монтирования, не удаляем."
            fi
        fi

        # Проверяем синтаксис compose-файла
        if ! $DOCKER_COMPOSE -f "$COMPOSE_FILE" config >/dev/null 2>&1; then
            echo "[!] Ошибка в $COMPOSE_FILE после удаления монтирования. Восстанавливаем бэкап..."
            mv "$COMPOSE_FILE.bak" "$COMPOSE_FILE"
        else
            rm -f "$COMPOSE_FILE.bak"
            echo "[✓] Монтирование сертификатов полностью удалено."

            # Перезапускаем remnanode, только если контейнер существует
            if docker ps -a --format '{{.Names}}' | grep -q "^remnanode$"; then
                echo "[*] Перезапускаем remnanode для применения изменений..."
                $DOCKER_COMPOSE -f "$COMPOSE_FILE" down
                $DOCKER_COMPOSE -f "$COMPOSE_FILE" up -d
            else
                echo "[*] Контейнер remnanode не запущен, перезапуск не требуется."
            fi
        fi
    else
        echo "[✓] Монтирование сертификатов не найдено."
    fi
else
    echo "[!] $COMPOSE_FILE не найден. Пропускаем удаление монтирования."
fi

echo "[✓] Откат Nginx + acme + FileCloud завершён."
echo "[!] 80 порт остался открытым, при необходимости закройте вручную командой ufw delete allow 80/tcp."
exit 0
