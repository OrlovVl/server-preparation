#!/bin/bash
set -o pipefail
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

# --- Определение команды docker compose ---
if docker compose version &> /dev/null; then
    DOCKER_COMPOSE="docker compose"
elif command -v docker-compose &> /dev/null; then
    DOCKER_COMPOSE="docker-compose"
else
    echo "[!] docker compose (или docker-compose) не установлен. Установите отдельно."
    exit 1
fi

# --- Функция очистки при прерывании ---
cleanup() {
    echo ""
    echo "[!] Получен сигнал прерывания. Выполняем очистку..."
    # Останавливаем и удаляем контейнеры, если они запущены
    if [[ -f "/opt/remnanode/caddy/docker-compose.yml" ]]; then
        cd /opt/remnanode/caddy
        $DOCKER_COMPOSE down || true
        cd /
    fi
    # Удаляем созданные папки
    rm -rf /opt/remnanode/caddy /opt/remnanode/filecloud
    echo "[✓] Очистка выполнена."
    exit 1
}
trap cleanup INT TERM

# --- Установка зависимостей ---
apt-get update
for pkg in wget unzip curl apache2-utils openssl; do
    if ! command -v "$pkg" &> /dev/null; then
        echo "[*] Устанавливаем $pkg..."
        apt-get install -y "$pkg"
    fi
done

# --- Парсинг аргументов ---
DOMAIN=""
PORKBUN_KEYS=""
WEB_PASSWORD=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --domain)
            DOMAIN="$2"
            shift 2
            ;;
        --porkbun-keys)
            PORKBUN_KEYS="$2"
            shift 2
            ;;
        --web-password)
            WEB_PASSWORD="$2"
            shift 2
            ;;
        --help|-h)
            echo "Использование: $0 --domain example.com --porkbun-keys 'pk1_... sk1_...' [--web-password 'pass']"
            exit 0
            ;;
        *)
            echo "[×] Неизвестный параметр: $1"
            echo "Используйте --help для справки."
            exit 1
            ;;
    esac
done

# --- Проверка обязательных параметров ---
if [[ -z "$DOMAIN" ]]; then
    echo "[×] Не указан домен. Используйте --domain example.com"
    exit 1
fi

if [[ -z "$PORKBUN_KEYS" ]]; then
    echo "[×] Не указаны ключи Porkbun. Используйте --porkbun-keys 'pk1_... sk1_...'"
    exit 1
fi

# Разбиваем строку ключей на два отдельных значения
read -r PORKBUN_API_KEY PORKBUN_SECRET <<< "$PORKBUN_KEYS"
if [[ -z "$PORKBUN_API_KEY" || -z "$PORKBUN_SECRET" ]]; then
    echo "[×] Ошибка: нужно передать два ключа (API Key и Secret Key) через пробел."
    echo "Пример: --porkbun-keys 'pk1_... sk1_...'"
    exit 1
fi

echo "[✓] Домен: $DOMAIN"
echo "[✓] Ключи приняты."

# ---- Вспомогательные функции ----

# Функция создания/обновления симлинков на сертификаты
setup_symlinks() {
    local cert_file="$1"
    local key_file="$2"
    echo "[*] Проверяем симлинки..."
    if [[ -L "/etc/ssl/certs/noctua.crt" && -L "/etc/ssl/private/noctua.key" ]]; then
        if [[ "$(readlink -f /etc/ssl/certs/noctua.crt)" == "$cert_file" && \
              "$(readlink -f /etc/ssl/private/noctua.key)" == "$key_file" ]]; then
            echo "[✓] Симлинки уже указывают на актуальные сертификаты."
            return 0
        else
            echo "[*] Симлинки существуют, но указывают на другие файлы. Обновляем..."
        fi
    else
        echo "[*] Симлинки отсутствуют. Создаём..."
    fi
    mkdir -p /etc/ssl/certs /etc/ssl/private
    ln -sf "$cert_file" /etc/ssl/certs/noctua.crt
    ln -sf "$key_file" /etc/ssl/private/noctua.key
    chmod 644 /etc/ssl/certs/noctua.crt
    chmod 600 /etc/ssl/private/noctua.key
    echo "[✓] Симлинки обновлены."
}

# Функция добавления монтирования сертификатов в docker-compose.yml remnanode
add_mount_to_remnanode() {
    local compose_file="/opt/remnanode/docker-compose.yml"
    if [[ ! -f "$compose_file" ]]; then
        echo "[!] $compose_file не найден. Монтирование пропущено."
        return 1
    fi
    echo "[*] Проверяем монтирование сертификатов в remnanode..."
    local mount_cert="      - /etc/ssl/certs/noctua.crt:/etc/ssl/certs/noctua.crt:ro"
    local mount_key="      - /etc/ssl/private/noctua.key:/etc/ssl/private/noctua.key:ro"

    if grep -q "$mount_cert" "$compose_file" && grep -q "$mount_key" "$compose_file"; then
        echo "[✓] Монтирование сертификатов уже присутствует в remnanode."
        return 0
    fi

    echo "[*] Добавляем монтирование в $compose_file..."
    cp "$compose_file" "$compose_file.bak"

    # Используем awk для вставки в конец блока remnanode
    awk -v mount_cert="$mount_cert" -v mount_key="$mount_key" '
    BEGIN { in_service=0; printed_volumes=0; }
    {
        if ($0 ~ /^  remnanode:/) {
            in_service=1
            print $0
            next
        }
        if (in_service) {
            if ($0 ~ /^  / && $0 !~ /^    /) {
                if (!printed_volumes) {
                    print "    volumes:"
                    print mount_cert
                    print mount_key
                    printed_volumes=1
                }
                print $0
                in_service=0
                next
            }
            print $0
            next
        }
        print $0
    }
    END {
        if (in_service && !printed_volumes) {
            print "    volumes:"
            print mount_cert
            print mount_key
        }
    }
    ' "$compose_file" > "$compose_file.tmp" && mv "$compose_file.tmp" "$compose_file"

    if ! $DOCKER_COMPOSE -f "$compose_file" config; then
        echo "[×] Ошибка в $compose_file после добавления монтирования. Восстанавливаем бэкап..."
        mv "$compose_file.bak" "$compose_file"
        return 1
    fi
    rm -f "$compose_file.bak"
    echo "[✓] Монтирование сертификатов добавлено в remnanode."

    echo "[*] Перезапускаем remnanode для применения монтирования..."
    $DOCKER_COMPOSE -f "$compose_file" down
    $DOCKER_COMPOSE -f "$compose_file" up -d
    return 0
}

# --- Проверка наличия сертификатов ---
CADDY_DIR="/opt/remnanode/caddy"
CERT_BASE="$CADDY_DIR/data/caddy/certificates"
CERT_DIR=""
CERT_FILE=""
KEY_FILE=""
CERT_EXISTS=false

if [[ -d "$CERT_BASE" ]]; then
    CERT_DIR=$(find "$CERT_BASE" -type d -name "*${DOMAIN}*" 2>/dev/null | head -1)
    if [[ -n "$CERT_DIR" ]]; then
        CERT_FILE="${CERT_DIR}/${DOMAIN}.crt"
        KEY_FILE="${CERT_DIR}/${DOMAIN}.key"
        if [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]]; then
            CERT_EXISTS=true
            echo "[✓] Сертификаты уже существуют: $CERT_DIR"
        fi
    fi
fi

# --- Если сертификаты уже есть, только проверяем симлинки и монтирование ---
if [[ "$CERT_EXISTS" == true ]]; then
    echo "[*] Сертификаты найдены. Проверяем симлинки и монтирование..."
    setup_symlinks "$CERT_FILE" "$KEY_FILE"
    add_mount_to_remnanode

    echo ""
    echo "[✓] Всё уже настроено. Завершаем."
    echo "================================================================================"
    echo "[*] Заглушка: https://${DOMAIN} (через fallback Xray)"
    echo "[*] Сертификаты: ${CERT_DIR}"
    echo "[*] Ссылки: /etc/ssl/certs/noctua.crt  и  /etc/ssl/private/noctua.key"
    echo "================================================================================"
    exit 0
fi

# --- Если сертификатов нет, выполняем полную установку ---
echo "[!] Сертификаты не найдены. Выполняем полную настройку..."

# --- Остановка и удаление старых контейнеров ---
if [[ -d "$CADDY_DIR" || -d "/opt/remnanode/filecloud" ]]; then
    echo "[!] Обнаружены существующие директории. Останавливаем и удаляем старые контейнеры..."
    if [[ -f "$CADDY_DIR/docker-compose.yml" ]]; then
        cd "$CADDY_DIR"
        $DOCKER_COMPOSE down || true
        cd /
    fi
    echo "[*] Удаляем старые папки..."
    rm -rf "$CADDY_DIR" /opt/remnanode/filecloud
fi

mkdir -p "$CADDY_DIR"/{data,config}
mkdir -p /opt/remnanode/filecloud

# --- Генерация пароля ---
if [[ -z "$WEB_PASSWORD" ]]; then
    WEB_PASSWORD=$(openssl rand -base64 32 | tr -d '\n=' | cut -c1-32)
fi
WEB_USER="admin"
echo "[*] Пароль для пользователя $WEB_USER: $WEB_PASSWORD"

# --- Установка сайта-заглушки ---
echo "[*] Устанавливаем FileCloud (простой HTTP-сервер)..."
cd /opt/remnanode/filecloud
wget --tries=5 --waitretry=10 --show-progress -O main.zip https://github.com/OrlovVl/server-preparation/archive/refs/heads/main.zip
unzip -o main.zip
cp -r server-preparation-main/filecloud/* .
rm -rf main.zip server-preparation-main

# --- Хеш пароля ---
echo "[*] Генерируем хеш пароля для базовой аутентификации..."
HASHED_PASSWORD=$(htpasswd -nbB "$WEB_USER" "$WEB_PASSWORD" | cut -d: -f2)

# --- Создаём .env файл с секретами ---
cat > "$CADDY_DIR"/.env <<EOF
PORKBUN_API_KEY=${PORKBUN_API_KEY}
PORKBUN_SECRET=${PORKBUN_SECRET}
EOF

# --- Caddyfile ---
cat > "$CADDY_DIR"/Caddyfile <<EOF
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

# --- docker-compose.yml для Caddy и FileCloud ---
cat > "$CADDY_DIR"/docker-compose.yml <<EOF
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

rm -f "$CADDY_DIR"/.password
echo "$WEB_PASSWORD" > "$CADDY_DIR"/.password
chmod 600 "$CADDY_DIR"/.password

# --- Запуск контейнеров ---
cd "$CADDY_DIR"
echo "[*] Запускаем контейнеры..."
$DOCKER_COMPOSE up -d

# --- Ожидание сертификатов ---
echo "[*] Ожидаем получения сертификатов. Логи Caddy будут выводиться в реальном времени."
echo "[*] Нажмите Ctrl+C, чтобы прервать ожидание (контейнеры продолжат работу)."
echo ""

show_logs_and_wait() {
    docker logs -f caddy &
    LOG_PID=$!

    while true; do
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

trap 'echo ""; echo "[!] Ожидание прервано пользователем."; kill $LOG_PID 2>/dev/null || true; cleanup; exit 1' INT

show_logs_and_wait

# --- После получения сертификатов создаём симлинки и монтируем ---
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

# Проверка валидности и создание симлинков
if openssl x509 -in "$CERT_FILE" -noout -checkend 86400 >/dev/null 2>&1; then
    setup_symlinks "$CERT_FILE" "$KEY_FILE"
else
    echo "[!] Сертификат истёк или невалиден. Симлинки не созданы."
    exit 1
fi

# Добавляем монтирование в remnanode
add_mount_to_remnanode

# --- Вывод логов remnanode ---
echo "[*] Просмотр логов контейнера remnanode (15 секунд)..."
timeout 15 $DOCKER_COMPOSE -f /opt/remnanode/docker-compose.yml logs -f || true
echo "[*] Продолжаем выполнение..."

# --- Снимаем trap после успешного выполнения ---
trap - INT TERM

echo ""
echo "[✓] Готово"
echo "================================================================================"
echo "[*] Заглушка: https://${DOMAIN} (через fallback Xray)"
echo "[*] Логин: ${WEB_USER}"
echo "[*] Пароль: ${WEB_PASSWORD} (сохранён в $CADDY_DIR/.password)"
echo "[*] Сертификаты: ${CERT_DIR}"
echo "[*] Ссылки: /etc/ssl/certs/noctua.crt  и  /etc/ssl/private/noctua.key"
echo "================================================================================"
sleep 2
exit 0
