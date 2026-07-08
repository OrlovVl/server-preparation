#!/bin/bash
set -o pipefail
set -e

if [ "$EUID" -ne 0 ]; then
    echo "[×] Запускайте от root."
    exit 1
fi

echo "[*] Откат Nginx + acme + FileCloud..."

# Останавливаем Nginx
systemctl stop nginx 2>/dev/null || true
systemctl disable nginx 2>/dev/null || true

# Удаляем конфиги сайта
rm -f /etc/nginx/sites-enabled/filecloud
rm -f /etc/nginx/sites-available/filecloud
rm -f /etc/nginx/.htpasswd

# Удаляем папку заглушки (если она существует и принадлежит нам)
if [[ -d "/opt/remnanode/filecloud" ]]; then
    rm -rf /opt/remnanode/filecloud
    echo "[✓] Папка заглушки удалена."
fi

# Удаляем симлинки сертификатов
if [[ -L "/etc/ssl/certs/noctua.crt" ]]; then
    rm -f /etc/ssl/certs/noctua.crt
fi
if [[ -L "/etc/ssl/private/noctua.key" ]]; then
    rm -f /etc/ssl/private/noctua.key
fi

# Удаляем сертификаты (опционально, но чтобы не оставлять мусор)
# rm -rf /etc/remna-certs  # если хотите удалить все сертификаты — раскомментируйте

# Удаляем маркер профиля, если он указывает на nginx
PROFILE_FILE="/opt/remnanode/.profile"
if [[ -f "$PROFILE_FILE" ]] && grep -q "nginx-acme" "$PROFILE_FILE"; then
    rm -f "$PROFILE_FILE"
    echo "[✓] Маркер профиля удалён."
fi

# Закрываем порт 80
if command -v ufw &> /dev/null; then
    if ufw status | grep -q "80/tcp"; then
        ufw delete allow 80/tcp 2>/dev/null || true
        echo "[✓] Порт 80 закрыт."
    fi
fi

echo "[✓] Откат Nginx + acme завершён."
exit 0