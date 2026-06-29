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

# --- Остановка и удаление старых контейнеров, если есть ---
if [[ -d "/opt/remnanode/caddy" || -d "/opt/remnanode/filecloud" ]]; then
    echo "[!] Обнаружены существующие директории. Останавливаем и удаляем старые контейнеры..."
    cd /opt/remnanode/caddy 2>/dev/null && {
        docker-compose down 2>/dev/null || true
        cd /
    }
    echo "[*] Удаляем старые папки..."
    rm -rf /opt/remnanode/caddy /opt/remnanode/filecloud
fi

mkdir -p /opt/remnanode/caddy/{data,config}
mkdir -p /opt/remnanode/filecloud

# --- Генерация пароля ---
if [[ -z "$WEB_PASSWORD" ]]; then
    WEB_PASSWORD=$(tr -dc 'A-Za-z0-9!@#$%^&*()_+-=' < /dev/urandom | head -c 32)
fi
WEB_USER="admin"
echo "[*] Пароль для пользователя $WEB_USER: $WEB_PASSWORD"

# --- Установка сайта-заглушки ---
echo "[*] Устанавливаем FileCloud (простой HTTP-сервер)..."
cd /opt/remnanode/filecloud
wget -q https://github.com/OrlovVl/server-preparation/archive/refs/heads/main.zip -O main.zip
unzip -q main.zip
cp -r server-preparation-main/filecloud/* .
rm -rf main.zip server-preparation-main

# --- Хеш пароля ---
echo "[*] Генерируем хеш пароля для базовой аутентификации..."
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
    basic_auth {
        ${WEB_USER} ${HASHED_PASSWORD}
    }
    reverse_proxy filecloud:8080
}
EOF

# --- .env файл для docker-compose ---
cat > /opt/remnanode/caddy/.env <<EOF
PORKBUN_API_KEY=${PORKBUN_API_KEY}
PORKBUN_SECRET=${PORKBUN_SECRET}
EOF

# --- docker-compose.yml ---
cat > /opt/remnanode/caddy/docker-compose.yml <<EOF
services:
  caddy:
    image: srstone/caddy-porkbun:latest
    container_name: caddy
    restart: always
    ports:
      - "127.0.0.1:8080:8080"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./data:/data
      - ./config:/config
    environment:
      - PORKBUN_API_KEY=\${PORKBUN_API_KEY}
      - PORKBUN_SECRET=\${PORKBUN_SECRET}

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

# --- Запуск контейнеров ---
cd /opt/remnanode/caddy
echo "[*] Запускаем контейнеры через docker-compose..."
docker-compose up -d

# --- Ожидание сертификатов с показом логов ---
echo "[*] Ожидаем получения сертификатов. Логи Caddy будут выводиться в реальном времени."
echo "[*] Нажмите Ctrl+C, чтобы прервать ожидание (контейнеры продолжат работу)."
echo ""

CERT_DIR="/opt/remnanode/caddy/data/certificates/acme-v02.api.letsencrypt.org/directory/${DOMAIN}"
CERT_FILE="${CERT_DIR}/${DOMAIN}.crt"
KEY_FILE="${CERT_DIR}/${DOMAIN}.key"

show_logs_and_wait() {
    docker logs -f caddy &
    LOG_PID=$!
    
    while true; do
        if [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]]; then
            echo ""
            echo "[✓] Сертификаты получены"
            kill $LOG_PID 2>/dev/null || true
            break
        fi
        sleep 2
    done
}

trap 'echo ""; echo "[!] Ожидание прервано пользователем."; kill $LOG_PID 2>/dev/null || true; exit 0' INT

show_logs_and_wait

# --- Создание симлинков ---
mkdir -p /etc/ssl/certs /etc/ssl/private
ln -sf "$CERT_FILE" /etc/ssl/certs/noctua.crt
ln -sf "$KEY_FILE" /etc/ssl/private/noctua.key
chmod 644 /etc/ssl/certs/noctua.crt
chmod 600 /etc/ssl/private/noctua.key

echo ""
echo "[✓] Готово"
echo "================================================================================"
echo "[*] Заглушка: https://${DOMAIN} (через fallback Xray)"
echo "[*] Логин: ${WEB_USER}"
echo "[*] Пароль: ${WEB_PASSWORD} (сохранён в /opt/remnanode/caddy/.password)"
echo "[*] Сертификаты: ${CERT_DIR}"
echo "[*] Ссылки: /etc/ssl/certs/noctua.crt  и  /etc/ssl/private/noctua.key"
echo "================================================================================"
