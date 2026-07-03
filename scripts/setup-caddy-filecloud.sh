#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
    echo "[×] Запускайте от root."
    exit 1
fi

# --- Проверка Docker ---
if ! command -v docker &> /dev/null; then
    echo "[!] Docker не установлен. Установите его (например, через curl -fsSL https://get.docker.com | sh)."
    exit 1
fi

# --- Определение команды docker compose (предпочтение без дефиса) ---
if docker compose version &> /dev/null; then
    DOCKER_COMPOSE="docker compose"
elif command -v docker-compose &> /dev/null; then
    DOCKER_COMPOSE="docker-compose"
else
    echo "[!] docker compose (или docker-compose) не установлен. Установите отдельно."
    exit 1
fi

# --- Установка зависимостей (wget, unzip, curl) ---
apt-get update
for pkg in wget unzip curl; do
    if ! command -v "$pkg" &> /dev/null; then
        echo "[*] Устанавливаем $pkg..."
        apt-get install -y "$pkg"
    fi
done

# --- Парсинг аргументов ---
DOMAIN=""
PORKBUN_API_KEY=""
PORKBUN_SECRET=""
WEB_PASSWORD=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --domain)
            DOMAIN="$2"
            shift 2
            ;;
        --porkbun-api-key)
            PORKBUN_API_KEY="$2"
            shift 2
            ;;
        --porkbun-secret)
            PORKBUN_SECRET="$2"
            shift 2
            ;;
        --web-password)
            WEB_PASSWORD="$2"
            shift 2
            ;;
        --help|-h)
            echo "Использование: $0 --domain example.com --porkbun-api-key 'key' --porkbun-secret 'secret' [--web-password 'pass']"
            exit 0
            ;;
        *)
            echo "[×] Неизвестный параметр: $1"
            exit 1
            ;;
    esac
done

if [[ -z "$DOMAIN" || -z "$PORKBUN_API_KEY" || -z "$PORKBUN_SECRET" ]]; then
    echo "[×] Использование: $0 --domain example.com --porkbun-api-key 'key' --porkbun-secret 'secret' [--web-password 'pass']"
    exit 1
fi

# --- Остановка и удаление старых контейнеров ---
if [[ -d "/opt/remnanode/caddy" || -d "/opt/remnanode/filecloud" ]]; then
    echo "[!] Обнаружены существующие директории. Останавливаем и удаляем старые контейнеры..."
    if [[ -f "/opt/remnanode/caddy/docker-compose.yml" ]]; then
        cd /opt/remnanode/caddy
        $DOCKER_COMPOSE down 2>/dev/null || true
        cd /
    fi
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
wget --show-progress -O main.zip https://github.com/OrlovVl/server-preparation/archive/refs/heads/main.zip
unzip -o main.zip
cp -r server-preparation-main/filecloud/* .
rm -rf main.zip server-preparation-main

# --- Хеш пароля ---
echo "[*] Генерируем хеш пароля для базовой аутентификации..."
HASHED_PASSWORD=$(docker run --rm caddy:latest caddy hash-password --plaintext "$WEB_PASSWORD" 2>/dev/null | tail -1)

# --- Создаём .env файл с секретами ---
cat > /opt/remnanode/caddy/.env <<EOF
PORKBUN_API_KEY=${PORKBUN_API_KEY}
PORKBUN_SECRET=${PORKBUN_SECRET}
EOF

# --- Caddyfile ---
cat > /opt/remnanode/caddy/Caddyfile <<EOF
${DOMAIN} {
    tls {
        dns porkbun {
            api_key {\$PORKBUN_API_KEY}
            api_secret_key {\$PORKBUN_SECRET}
        }
    }
    basic_auth {
        ${WEB_USER} ${HASHED_PASSWORD}
    }
    reverse_proxy filecloud:8080
}
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

rm -f /opt/remnanode/caddy/.password
echo "$WEB_PASSWORD" > /opt/remnanode/caddy/.password
chmod 600 /opt/remnanode/caddy/.password

# --- Запуск контейнеров ---
cd /opt/remnanode/caddy
echo "[*] Запускаем контейнеры через $DOCKER_COMPOSE..."
$DOCKER_COMPOSE up -d

# --- Ожидание сертификатов с показом логов ---
echo "[*] Ожидаем получения сертификатов. Логи Caddy будут выводиться в реальном времени."
echo "[*] Нажмите Ctrl+C, чтобы прервать ожидание (контейнеры продолжат работу)."
echo ""

show_logs_and_wait() {
    docker logs -f caddy &
    LOG_PID=$!

    while true; do
        CERT_BASE="/opt/remnanode/caddy/data/caddy/certificates"
        if [[ -d "$CERT_BASE" ]]; then
            CERT_DIR=$(find "$CERT_BASE" -type d -name "*${DOMAIN}*" 2>/dev/null | head -1)
            if [[ -n "$CERT_DIR" ]]; then
                CERT_FILE="${CERT_DIR}/${DOMAIN}.crt"
                KEY_FILE="${CERT_DIR}/${DOMAIN}.key"
                if [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]]; then
                    echo ""
                    echo "[✓] Сертификаты получены!"
                    kill $LOG_PID 2>/dev/null || true
                    break
                fi
            fi
        fi
        sleep 2
    done
}

trap 'echo ""; echo "[!] Ожидание прервано пользователем."; kill $LOG_PID 2>/dev/null || true; exit 0' INT

show_logs_and_wait

# --- После получения сертификатов создаём симлинки ---
CERT_BASE="/opt/remnanode/caddy/data/caddy/certificates"
CERT_DIR=$(find "$CERT_BASE" -type d -name "*${DOMAIN}*" | head -1)
if [[ -z "$CERT_DIR" ]]; then
    echo "[!] Не удалось найти папку с сертификатами. Симлинки не созданы."
    exit 1
fi

CERT_FILE="${CERT_DIR}/${DOMAIN}.crt"
KEY_FILE="${CERT_DIR}/${DOMAIN}.key"

if [[ ! -f "$CERT_FILE" || ! -f "$KEY_FILE" ]]; then
    echo "[!] Файлы сертификатов не найдены в $CERT_DIR"
    exit 1
fi

mkdir -p /etc/ssl/certs /etc/ssl/private

# Проверяем валидность сертификата (не истёк и существует)
if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
    if openssl x509 -in "$CERT_FILE" -noout -checkend 86400 >/dev/null 2>&1; then
        ln -sf "$CERT_FILE" /etc/ssl/certs/noctua.crt
        ln -sf "$KEY_FILE" /etc/ssl/private/noctua.key
        chmod 644 /etc/ssl/certs/noctua.crt
        chmod 600 /etc/ssl/private/noctua.key
        echo "[✓] Симлинки созданы и указывают на актуальные сертификаты."
    else
        echo "[!] Сертификат истёк или невалиден. Симлинки не созданы."
        exit 1
    fi
else
    echo "[!] Файлы сертификатов не найдены. Симлинки не созданы."
    exit 1
fi

# --- Монтирование сертификатов в контейнер remnanode (если существует) ---
REMNA_NODE_COMPOSE="/opt/remnanode/docker-compose.yml"
if [[ -f "$REMNA_NODE_COMPOSE" ]]; then
    echo "[*] Обнаружен docker-compose.yml для remnanode. Добавляем монтирование сертификатов..."

    cd /opt/remnanode

    # Строки монтирования
    MOUNT_CERT="      - /etc/ssl/certs/noctua.crt:/etc/ssl/certs/noctua.crt:ro"
    MOUNT_KEY="      - /etc/ssl/private/noctua.key:/etc/ssl/private/noctua.key:ro"

    # Проверяем, есть ли уже такие строки (чтобы не дублировать)
    if grep -q "$MOUNT_CERT" "$REMNA_NODE_COMPOSE" && grep -q "$MOUNT_KEY" "$REMNA_NODE_COMPOSE"; then
        echo "[✓] Монтирование сертификатов уже присутствует в remnanode."
    else
        # Создаём бэкап
        cp "$REMNA_NODE_COMPOSE" "$REMNA_NODE_COMPOSE.bak"

        # Удаляем возможные старые строки (на случай если они частично остались)
        sed -i "\|$MOUNT_CERT|d" "$REMNA_NODE_COMPOSE"
        sed -i "\|$MOUNT_KEY|d" "$REMNA_NODE_COMPOSE"

        # Проверяем, есть ли секция volumes у сервиса remnanode
        if grep -A20 "^  remnanode:" "$REMNA_NODE_COMPOSE" | grep -q "^    volumes:"; then
            # Секция volumes уже есть – добавляем наши строки в конец блока (перед следующей секцией)
            # Вставляем строки перед строкой с отступом 2 пробела (закрытие блока)
            sed -i "/^    volumes:/,/^  / {
                /^  / i\\
$MOUNT_CERT
                /^  / i\\
$MOUNT_KEY
            }" "$REMNA_NODE_COMPOSE"
        else
            # Секции volumes нет – создаём после строки "    environment:" или "    image:"
            # Ищем "    environment:" – если есть, вставляем после неё, иначе после "    image:"
            if grep -q "^    environment:" "$REMNA_NODE_COMPOSE"; then
                sed -i "/^    environment:/a\\
    volumes:\\n$MOUNT_CERT\\n$MOUNT_KEY" "$REMNA_NODE_COMPOSE"
            else
                sed -i "/^    image:/a\\
    volumes:\\n$MOUNT_CERT\\n$MOUNT_KEY" "$REMNA_NODE_COMPOSE"
            fi
        fi

        # Проверяем синтаксис compose-файла
        if ! $DOCKER_COMPOSE -f "$REMNA_NODE_COMPOSE" config &> /dev/null; then
            echo "[×] Ошибка в $REMNA_NODE_COMPOSE после добавления монтирования. Восстанавливаем бэкап..."
            mv "$REMNA_NODE_COMPOSE.bak" "$REMNA_NODE_COMPOSE"
            exit 1
        fi
        rm -f "$REMNA_NODE_COMPOSE.bak"

        echo "[✓] Монтирование сертификатов добавлено в remnanode."

        # Перезапускаем remnanode, чтобы применить изменения
        echo "[*] Перезапускаем remnanode для применения монтирования..."
        $DOCKER_COMPOSE -f "$REMNA_NODE_COMPOSE" down
        $DOCKER_COMPOSE -f "$REMNA_NODE_COMPOSE" up -d
    fi
else
    echo "[!] /opt/remnanode/docker-compose.yml не найден. Монтирование сертификатов в remnanode пропущено."
fi

echo ""
echo "[✓] Готово"
echo "================================================================================"
echo "[*] Заглушка: https://${DOMAIN} (через fallback Xray)"
echo "[*] Логин: ${WEB_USER}"
echo "[*] Пароль: ${WEB_PASSWORD} (сохранён в /opt/remnanode/caddy/.password)"
echo "[*] Сертификаты: ${CERT_DIR}"
echo "[*] Ссылки: /etc/ssl/certs/noctua.crt  и  /etc/ssl/private/noctua.key"
echo "================================================================================"
exit 0
