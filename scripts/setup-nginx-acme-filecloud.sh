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

# --- Установка yq ---
if ! command -v yq &> /dev/null; then
    echo "[*] Устанавливаем yq..."
    local arch=$(uname -m)
    case "$arch" in
        x86_64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) echo "[×] Неподдерживаемая архитектура: $arch"; exit 1 ;;
    esac
    curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${arch}" -o /usr/local/bin/yq
    chmod +x /usr/local/bin/yq
fi
echo "[✓] yq готов."

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

CERT_DOMAIN="$DOMAIN"
CERT_DIR_ACME="/root/.acme.sh/${CERT_DOMAIN}_ecc"
NEED_ISSUE=false

# Проверяем, существует ли домен в списке acme.sh
if "$ACME" --list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$CERT_DOMAIN"; then
    # Проверяем наличие файлов сертификата
    if [[ -f "$CERT_DIR_ACME/${CERT_DOMAIN}.key" && -f "$CERT_DIR_ACME/fullchain.cer" ]]; then
        echo "[✓] Сертификат уже существует, пропускаем issue."
    else
        echo "[!] Сертификат найден в списке, но файлы отсутствуют. Перевыпускаем..."
        "$ACME" --remove -d "$CERT_DOMAIN" 2>/dev/null || true
        NEED_ISSUE=true
    fi
else
    NEED_ISSUE=true
fi

if [[ "$NEED_ISSUE" == true ]]; then
    # Останавливаем nginx перед выпуском (если он запущен)
    systemctl stop nginx 2>/dev/null || true
    echo "[*] Выпускаем сертификат (standalone)..."
    "$ACME" --issue --standalone -d "$CERT_DOMAIN" --keylength ec-256 \
        --pre-hook "systemctl stop nginx 2>/dev/null || true" \
        --post-hook "systemctl start nginx 2>/dev/null || true" || {
            echo "[×] Не удалось выпустить сертификат. Проверьте DNS и доступность порта 80."
            systemctl start nginx 2>/dev/null || true
            exit 1
        }
    systemctl start nginx 2>/dev/null || true
    echo "[✓] Сертификат успешно выпущен."
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

# --- Создание симлинков для постоянного доступа ---
mkdir -p /etc/ssl/certs /etc/ssl/private
ln -sf "$CERT_DIR/fullchain.pem" /etc/ssl/certs/noctua.crt
ln -sf "$CERT_DIR/key.pem" /etc/ssl/private/noctua.key
echo "[✓] Симлинки созданы: /etc/ssl/certs/noctua.crt -> $CERT_DIR/fullchain.pem"
echo "[✓] Симлинки созданы: /etc/ssl/private/noctua.key -> $CERT_DIR/key.pem"

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

# --- Монтирование сертификатов в контейнер remnanode ---
local compose_file="/opt/remnanode/docker-compose.yml"
if [[ ! -f "$compose_file" ]]; then
    echo "[!] $compose_file не найден. Монтирование пропущено."
    return 1
fi
echo "[*] Проверяем монтирование сертификатов в remnanode..."
local mount_cert="/etc/ssl/certs/noctua.crt:/etc/ssl/certs/noctua.crt:ro"
local mount_key="/etc/ssl/private/noctua.key:/etc/ssl/private/noctua.key:ro"
# Проверяем наличие обоих монтирований
local existing_cert=$(yq eval ".services.remnanode.volumes[] | select(. == \"$mount_cert\")" "$compose_file")
local existing_key=$(yq eval ".services.remnanode.volumes[] | select(. == \"$mount_key\")" "$compose_file")
if [[ -n "$existing_cert" && -n "$existing_key" ]]; then
    echo "[✓] Монтирование сертификатов уже присутствует в remnanode."
    return 0
fi
echo "[*] Добавляем монтирование в $compose_file..."
cp "$compose_file" "$compose_file.bak"
# Если секция volumes отсутствует, создаём её
if ! yq eval '.services.remnanode.volumes' "$compose_file" &>/dev/null; then
    yq eval '.services.remnanode.volumes = []' -i "$compose_file"
fi
# Добавляем отсутствующие монтирования
if [[ -z "$existing_cert" ]]; then
    yq eval ".services.remnanode.volumes += [\"$mount_cert\"]" -i "$compose_file"
fi
if [[ -z "$existing_key" ]]; then
    yq eval ".services.remnanode.volumes += [\"$mount_key\"]" -i "$compose_file"
fi
# Проверка синтаксиса
if ! $DOCKER_COMPOSE -f "$compose_file" config >/dev/null 2>&1; then
    echo "[×] Ошибка в $compose_file после добавления монтирования. Восстанавливаем бэкап..."
    mv "$compose_file.bak" "$compose_file"
    return 1
fi
rm -f "$compose_file.bak"
echo "[✓] Монтирование сертификатов добавлено в remnanode."
echo "[*] Перезапускаем remnanode для применения монтирования..."
$DOCKER_COMPOSE -f "$compose_file" down
$DOCKER_COMPOSE -f "$compose_file" up -d

# --- Вывод логов remnanode ---
echo "[*] Просмотр логов контейнера remnanode (15 секунд)..."
timeout 15 $DOCKER_COMPOSE -f /opt/remnanode/docker-compose.yml logs -f || true
echo "[*] Продолжаем выполнение..."

echo ""
echo "[✓] Настройка Nginx + acme + FileCloud завершена."
echo "[*] Сертификаты: $CERT_DIR"
echo "[*] Симлинки:"
echo "    /etc/ssl/certs/noctua.crt -> $CERT_DIR/fullchain.pem"
echo "    /etc/ssl/private/noctua.key -> $CERT_DIR/key.pem"
echo "[*] Заглушка доступна локально: https://127.0.0.1:$FALLBACK_PORT"
echo "[*] Логин: $WEB_USER, пароль: $WEB_PASSWORD"
echo "[*] Конфиг Nginx: /etc/nginx/sites-available/filecloud"
echo "[*] Сертификаты смонтированы в контейнер remnanode через симлинки (если он есть)."
exit 0
