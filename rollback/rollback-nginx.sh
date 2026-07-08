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

# Удаляем сертификаты (опционально, но чтобы не оставлять мусор)
# rm -rf /etc/remna-certs

# Удаляем маркер профиля, если он указывает на nginx
PROFILE_FILE="/opt/remnanode/.profile"
if [[ -f "$PROFILE_FILE" ]] && grep -q "nginx-acme" "$PROFILE_FILE"; then
    rm -f "$PROFILE_FILE"
    echo "[✓] Маркер профиля удалён."
fi

echo "[✓] Откат Nginx + acme завершён."
echo "[!] 80 порт остался открытым, при необходимости закройте вручную командой ufw delete allow 80/tcp."
exit 0