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
    echo "[!] Прервано. Выполняем очистку..."
    systemctl stop nginx 2>/dev/null || true
    rm -f /etc/nginx/sites-enabled/filecloud 2>/dev/null || true
    rm -f /etc/nginx/sites-available/filecloud 2>/dev/null || true
    echo "[✓] Очистка выполнена."
    exit 1
}
trap cleanup INT TERM

# --- Парсинг аргументов ---
DOMAIN=""
EMAIL=""
FALLBACK_PORT="8080"
WEB_USER="admin"
WEB_PASSWORD=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --domain)
            DOMAIN="$2"
            shift 2
            ;;
        --email)
            EMAIL="$2"
            shift 2
            ;;
        --fallback-port)
            FALLBACK_PORT="$2"
            shift 2
            ;;
        --web-password)
            WEB_PASSWORD="$2"
            shift 2
            ;;
        --help|-h)
            echo "Использование: $0 --domain example.com [--email admin@example.com] [--fallback-port 8080] [--web-password 'pass']"
            exit 0
            ;;
        *)
            echo "[×] Неизвестный параметр: $1"
            exit 1
            ;;
    esac
done

if [[ -z "$DOMAIN" ]]; then
    echo "[×] Не указан домен. Используйте --domain example.com"
    exit 1
fi

[[ -z "$EMAIL" ]] && EMAIL="admin@${DOMAIN}"
echo "[*] Email: $EMAIL"

# --- Генерация пароля ---
if [[ -z "$WEB_PASSWORD" ]]; then
    WEB_PASSWORD=$(openssl rand -base64 32 | tr -d '\n=' | cut -c1-32)
fi
echo "[*] Пароль для пользователя $WEB_USER: $WEB_PASSWORD"

# --- Установка пакетов ---
apt-get update
for pkg in nginx curl socat apache2-utils openssl wget unzip; do
    if ! command -v $pkg &> /dev/null; then
        echo "[*] Устанавливаем $pkg..."
        apt-get install -y $pkg
    fi
done

# --- acme.sh ---
if [[ ! -x /root/.acme.sh/acme.sh ]]; then
    echo "[*] Устанавливаем acme.sh..."
    curl -fsSL https://get.acme.sh | sh -s email="$EMAIL"
fi
ACME="/root/.acme.sh/acme.sh"
[[ -x "$ACME" ]] || { echo "[×] acme.sh не найден."; exit 1; }

# --- Выпуск сертификата (HTTP-01) ---
echo "[*] Выпускаем сертификат для $DOMAIN..."
# Открываем порт 80, если ещё не открыт
if command -v ufw &> /dev/null; then
    if ! ufw status | grep -q "80/tcp"; then
        ufw allow 80/tcp
        echo "[*] Порт 80 открыт для HTTP-01."
    fi
fi

if "$ACME" --list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$DOMAIN"; then
    echo "[✓] Сертификат уже существует, пропускаем issue."
else
    # Останавливаем nginx перед выпуском (освобождаем порт 80)
    # pre-hook и post-hook также будут использоваться при автоматическом обновлении через cron
    "$ACME" --issue --standalone -d "$DOMAIN" --keylength ec-256 \
        --pre-hook "systemctl stop nginx 2>/dev/null || true" \
        --post-hook "systemctl start nginx 2>/dev/null || true" \
        || {
            echo "[×] Не удалось выпустить сертификат. Проверьте DNS и доступность порта 80."
            # Восстанавливаем nginx
            systemctl start nginx 2>/dev/null || true
            exit 1
        }
fi

# --- Установка сертификатов ---
CERT_DIR="/etc/node-certs/$DOMAIN"
mkdir -p "$CERT_DIR"
"$ACME" --install-cert -d "$DOMAIN" --ecc \
    --key-file "$CERT_DIR/key.pem" \
    --fullchain-file "$CERT_DIR/fullchain.pem" \
    --reloadcmd "systemctl reload nginx || true" \
    || echo "[!] install-cert не удался."

chmod 600 "$CERT_DIR/key.pem"
chmod 644 "$CERT_DIR/fullchain.pem"

# --- Установка FileCloud (заглушка) ---
FILECLOUD_DIR="/opt/remnanode/filecloud"
if [[ ! -d "$FILECLOUD_DIR" ]]; then
    echo "[*] Устанавливаем FileCloud (заглушку)..."
    mkdir -p "$FILECLOUD_DIR"
    cd "$FILECLOUD_DIR"
    wget --tries=5 --waitretry=10 --show-progress -O main.zip \
        https://github.com/OrlovVl/server-preparation/archive/refs/heads/main.zip
    unzip -o main.zip
    cp -r server-preparation-main/filecloud/* .
    rm -rf main.zip server-preparation-main
else
    echo "[*] FileCloud уже установлен."
fi

# --- Настройка Nginx с Basic Auth ---
# Создаём файл паролей
HTPASSWD_FILE="/etc/nginx/.htpasswd"
htpasswd -bBc "$HTPASSWD_FILE" "$WEB_USER" "$WEB_PASSWORD"
chmod 644 "$HTPASSWD_FILE"

# Создаём конфиг сайта
cat > /etc/nginx/sites-available/filecloud <<EOF
server {
    listen 127.0.0.1:$FALLBACK_PORT ssl;
    server_name $DOMAIN;

    ssl_certificate $CERT_DIR/fullchain.pem;
    ssl_certificate_key $CERT_DIR/key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    root $FILECLOUD_DIR;
    index index.html;

    auth_basic "Restricted Access";
    auth_basic_user_file $HTPASSWD_FILE;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

# Включаем сайт
ln -sf /etc/nginx/sites-available/filecloud /etc/nginx/sites-enabled/

# Проверка конфига
nginx -t || { echo "[×] Ошибка в конфигурации Nginx."; exit 1; }

# --- Перезапуск Nginx ---
systemctl enable nginx
systemctl restart nginx

# --- Монтирование сертификатов в контейнер remnanode (без симлинков) ---
add_mount_to_remnanode() {
    local compose_file="/opt/remnanode/docker-compose.yml"
    if [[ ! -f "$compose_file" ]]; then
        echo "[!] $compose_file не найден. Монтирование пропущено."
        return 1
    fi
    echo "[*] Проверяем монтирование сертификатов в remnanode..."
    local mount_cert="      - $CERT_DIR/fullchain.pem:/etc/ssl/certs/noctua.crt:ro"
    local mount_key="      - $CERT_DIR/key.pem:/etc/ssl/private/noctua.key:ro"

    if grep -q "$mount_cert" "$compose_file" && grep -q "$mount_key" "$compose_file"; then
        echo "[✓] Монтирование сертификатов уже присутствует в remnanode."
        return 0
    fi

    echo "[*] Добавляем монтирование в $compose_file..."
    cp "$compose_file" "$compose_file.bak"

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

add_mount_to_remnanode

# --- Вывод логов remnanode ---
echo "[*] Просмотр логов контейнера remnanode (15 секунд)..."
timeout 15 $DOCKER_COMPOSE -f /opt/remnanode/docker-compose.yml logs -f || true
echo "[*] Продолжаем выполнение..."

echo ""
echo "[✓] Настройка Nginx + acme + FileCloud завершена."
echo "[*] Сертификаты: $CERT_DIR"
echo "[*] Заглушка доступна локально: https://127.0.0.1:$FALLBACK_PORT"
echo "[*] Логин: $WEB_USER, пароль: $WEB_PASSWORD"
echo "[*] Конфиг Nginx: /etc/nginx/sites-available/filecloud"
echo "[*] Сертификаты смонтированы в контейнер remnanode (если он есть)."
exit 0
