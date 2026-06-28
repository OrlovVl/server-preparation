#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "[×] Этот скрипт нужно запускать от имени root (или через sudo)."
  exit 1
fi

# --- Проверка Docker и docker-compose ---
if ! command -v docker &> /dev/null; then
  echo "[!] Docker не установлен. Установите его (например, через curl -fsSL https://get.docker.com | sh)."
  exit 1
fi
if ! command -v docker-compose &> /dev/null; then
  echo "[!] docker-compose не установлен. Установите его отдельно."
  exit 1
fi

# --- Установка остальных зависимостей ---
apt-get update -qq
for pkg in wget unzip curl; do
  if ! command -v $pkg &> /dev/null; then
    echo "[*] Устанавливаем $pkg..."
    apt-get install -y -qq $pkg
  fi
done

# --- Парсинг аргументов ---
DOMAIN=""
PORKBUN_API_KEY=""
PORKBUN_SECRET=""
WEB_PASSWORD=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --domain) DOMAIN="$2"; shift 2 ;;
        --porkbun-api-key) PORKBUN_API_KEY="$2"; shift 2 ;;
        --porkbun-secret) PORKBUN_SECRET="$2"; shift 2 ;;
        --web-password) WEB_PASSWORD="$2"; shift 2 ;;
        *) echo "[×] Неизвестный параметр: $1"; exit 1 ;;
    esac
done

if [[ -z "$DOMAIN" || -z "$PORKBUN_API_KEY" || -z "$PORKBUN_SECRET" ]]; then
    echo "[×] Использование: $0 --domain example.com --porkbun-api-key 'key' --porkbun-secret 'secret' [--web-password 'pass']"
    exit 1
fi

# --- Удаление старых данных ---
if [[ -d "/opt/remnanode/caddy" || -d "/opt/remnanode/filecloud" ]]; then
    echo "[!] Обнаружены существующие директории. Переустановка..."
    cd /opt/remnanode/caddy 2>/dev/null && docker-compose down 2>/dev/null || true
    rm -rf /opt/remnanode/caddy /opt/remnanode/filecloud
fi

mkdir -p /opt/remnanode/caddy/{data,config}
mkdir -p /opt/remnanode/filecloud

# --- Генерация пароля ---
if [[ -z "$WEB_PASSWORD" ]]; then
    WEB_PASSWORD=$(tr -dc 'A-Za-z0-9!@#$%^&*()_+-=' < /dev/urandom | head -c 32)
fi
WEB_USER="admin"

# --- Установка сайта-заглушки ---
echo "[*] Устанавливаем FileCloud..."
cd /opt/remnanode/filecloud
wget -q https://github.com/OrlovVl/server-preparation/archive/refs/heads/main.zip -O main.zip
unzip -q main.zip
cp -r server-preparation-main/filecloud/* .
rm -rf main.zip server-preparation-main

# --- Хеш пароля ---
HASHED_PASSWORD=$(docker run --rm caddy:latest caddy hash-password --plaintext "$WEB_PASSWORD" 2>/dev/null | tail -1)

# --- Caddyfile ---
cat > /opt/remnanode/caddy/Caddyfile <<EOF
${DOMAIN} {
    tls {
        dns porkbun {
            api_key {$PORKBUN_API_KEY}
            api_secret_key {$PORKBUN_SECRET}
        }
    }
    basicauth {
        ${WEB_USER} ${HASHED_PASSWORD}
    }
    reverse_proxy filecloud:8080
}
EOF

# --- docker-compose.yml ---
cat > /opt/remnanode/caddy/docker-compose.yml <<EOF
services:
  caddy:
    image: caddy:latest
    container_name: caddy
    restart: always
    ports:
      - "127.0.0.1:8080:8080"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./data:/data
      - ./config:/config
    environment:
      - PORKBUN_API_KEY=${PORKBUN_API_KEY}
      - PORKBUN_API_SECRET_KEY=${PORKBUN_SECRET}

  filecloud:
    image: python:3-alpine
    container_name: filecloud
    restart: always
    working_dir: /app
    command: python -m http.server 8080 --bind 0.0.0.0
    volumes:
      - /opt/remnanode/filecloud:/app
EOF

echo "$WEB_PASSWORD" > /opt/remnanode/caddy/.password
chmod 600 /opt/remnanode/caddy/.password

# --- Запуск ---
cd /opt/remnanode/caddy
docker-compose up -d

# --- Ожидание сертификатов и создание ссылок ---
echo "[*] Ожидаем получения сертификатов (до 60 сек)..."
CERT_DIR="/opt/remnanode/caddy/data/certificates/acme-v02.api.letsencrypt.org/directory/${DOMAIN}"
CERT_FILE="${CERT_DIR}/${DOMAIN}.crt"
KEY_FILE="${CERT_DIR}/${DOMAIN}.key"

WAIT=0
TIMEOUT=60
while [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; do
    sleep 5
    WAIT=$((WAIT+5))
    if [ $WAIT -ge $TIMEOUT ]; then
        echo "[!] Сертификаты не появились за $TIMEOUT сек. Проверьте логи: docker logs caddy"
        echo "[!] Ссылки не созданы. Создайте вручную позже."
        exit 0
    fi
    echo "[*] Ждём... $WAIT сек"
done

mkdir -p /etc/ssl/certs /etc/ssl/private
ln -sf "$CERT_FILE" /etc/ssl/certs/vpn.crt
ln -sf "$KEY_FILE" /etc/ssl/private/vpn.key
chmod 644 /etc/ssl/certs/vpn.crt
chmod 600 /etc/ssl/private/vpn.key

echo "[✓] Готово"
echo "================================================================================"
echo "[*] Заглушка: https://${DOMAIN} (через fallback Xray)"
echo "[*] Логин: ${WEB_USER}"
echo "[*] Пароль: ${WEB_PASSWORD} (сохранён в /opt/remnanode/caddy/.password)"
echo "[*] Сертификаты: ${CERT_DIR}"
echo "[*] Ссылки: /etc/ssl/certs/vpn.crt  и  /etc/ssl/private/vpn.key"
echo "================================================================================"
