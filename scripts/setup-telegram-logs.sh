#!/bin/bash
set -o pipefail
set -e

if [ "$EUID" -ne 0 ]; then
    echo "[×] Запускайте от root."
    exit 1
fi

# --- Парсинг аргументов ---
BOT_TOKEN=""
CHAT_ID=""
PREFIX=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --token)
            BOT_TOKEN="$2"
            shift 2
            ;;
        --chat-id)
            CHAT_ID="$2"
            shift 2
            ;;
        --prefix)
            PREFIX="$2"
            shift 2
            ;;
        --help|-h)
            cat <<HELP
Использование: $0 --token <BOT_TOKEN> --chat-id <CHAT_ID> [--prefix NAME]

Обязательные параметры:
  --token      Telegram Bot Token
  --chat-id    Chat ID для отправки

Опциональные параметры:
  --prefix     Префикс для названия файлов (по умолчанию hostname)

Логи access.log и error.log ротируются по отдельности при достижении 46 МБ.
Отправка из очереди каждые 2 минуты.
HELP
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
if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]]; then
    echo "[×] Обязательные параметры --token и --chat-id не указаны."
    exit 1
fi

# --- Установка префикса по умолчанию ---
[[ -z "$PREFIX" ]] && PREFIX=$(hostname)

# --- Проверка Docker ---
if ! command -v docker &> /dev/null; then
    echo "[!] Docker не установлен."
    exit 1
fi

# --- Определение docker compose ---
if docker compose version &> /dev/null; then
    DOCKER_COMPOSE="docker compose"
elif command -v docker-compose &> /dev/null; then
    DOCKER_COMPOSE="docker-compose"
else
    echo "[!] docker compose не установлен."
    exit 1
fi

# --- Проверка наличия ноды ---
COMPOSE_FILE="/opt/remnanode/docker-compose.yml"
if [[ ! -f "$COMPOSE_FILE" ]]; then
    echo "[×] $COMPOSE_FILE не найден. Сначала выполните setup-node.sh."
    exit 1
fi

# --- trap ---
cleanup() {
    echo ""
    echo "[!] Прервано. Выполняем откат..."
    if [[ -f "$COMPOSE_FILE" && -f "$COMPOSE_FILE.bak" ]]; then
        mv "$COMPOSE_FILE.bak" "$COMPOSE_FILE"
        echo "[✓] Восстановлен бэкап $COMPOSE_FILE"
    fi
    rm -f /usr/local/bin/send-xray-logs.sh 2>/dev/null || true
    rm -f /usr/local/bin/send-xray-logs-now.sh 2>/dev/null || true
    if crontab -l 2>/dev/null | grep -q "send-xray-logs.sh"; then
        crontab -l 2>/dev/null | grep -v "send-xray-logs.sh" | crontab - 2>/dev/null || true
    fi
    echo "[✓] Очистка выполнена."
    exit 1
}
trap cleanup INT TERM

# --- Установка зависимостей ---
echo "[*] Устанавливаем logrotate и curl..."
apt-get update
for pkg in logrotate curl; do
    if ! command -v $pkg &> /dev/null; then
        apt-get install -y $pkg
    fi
done

# --- Добавление монтирование папки для логов ---
echo "[*] Добавляем монтирование для логов в $COMPOSE_FILE..."
if grep -q "/var/log/xray" "$COMPOSE_FILE"; then
    echo "[✓] Монтирование для логов уже присутствует."
else
    cp "$COMPOSE_FILE" "$COMPOSE_FILE.bak"
    MOUNT_LINE="      - /opt/remnanode/logs:/var/log/xray"
    awk -v mount_line="$MOUNT_LINE" '
    BEGIN { in_service=0; in_vol=0; added=0; }
    {
        if ($0 ~ /^  remnanode:/) {
            in_service=1
            print $0
            next
        }
        if (in_service) {
            if ($0 ~ /^    volumes:/) {
                in_vol=1
                print $0
                while ((getline) > 0) {
                    if ($0 ~ /^  / && $0 !~ /^    /) {
                        if (!added) {
                            print mount_line
                            added=1
                        }
                        print $0
                        in_vol=0
                        in_service=0
                        break
                    } else {
                        print $0
                    }
                }
                if (in_vol && !added) {
                    print mount_line
                    added=1
                }
                next
            }
            if ($0 ~ /^  / && $0 !~ /^    /) {
                if (!added) {
                    print "    volumes:"
                    print mount_line
                    added=1
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
        if (in_service && !added) {
            print "    volumes:"
            print mount_line
        }
    }
    ' "$COMPOSE_FILE" > "$COMPOSE_FILE.tmp" && mv "$COMPOSE_FILE.tmp" "$COMPOSE_FILE"
    if ! $DOCKER_COMPOSE -f "$COMPOSE_FILE" config >/dev/null 2>&1; then
        echo "[×] Ошибка в $COMPOSE_FILE после добавления монтирования. Восстанавливаем бэкап..."
        mv "$COMPOSE_FILE.bak" "$COMPOSE_FILE"
        exit 1
    fi
    rm -f "$COMPOSE_FILE.bak"
    echo "[✓] Монтирование для логов добавлено."
fi

# --- Перезапуск контейнера ---
echo "[*] Перезапускаем remnanode..."
$DOCKER_COMPOSE -f "$COMPOSE_FILE" down
$DOCKER_COMPOSE -f "$COMPOSE_FILE" up -d
sleep 3
if ! docker ps --format '{{.Names}}' | grep -q "^remnanode$"; then
    echo "[×] Контейнер remnanode не запустился."
    exit 1
fi
echo "[✓] Контейнер запущен."

# --- Вывод логов remnanode ---
echo "[*] Просмотр логов контейнера remnanode (15 секунд)..."
timeout 15 $DOCKER_COMPOSE -f /opt/remnanode/docker-compose.yml logs -f || true
echo "[*] Продолжаем выполнение..."

# --- Создаём папку для логов ---
mkdir -p /opt/remnanode/logs
if [ ! -w "/opt/remnanode/logs" ]; then
    echo "[×] Папка /opt/remnanode/logs недоступна для записи."
    exit 1
fi

# --- Конфиги logrotate для access и error ---
LOGROTATE_ACCESS="/etc/logrotate.d/remnanode-xray-access"
cat > "$LOGROTATE_ACCESS" <<EOF
/opt/remnanode/logs/access.log {
    size 46M
    rotate 1
    copytruncate
    nocompress
    notifempty
    create 0644 root root
    postrotate
        if [[ -f "/opt/remnanode/logs/access.log.1" ]]; then
            TIMESTAMP=\$(date +%Y%m%d-%H%M%S)
            PENDING_DIR="/tmp/xray-logs-pending"
            mkdir -p "\$PENDING_DIR"
            mv /opt/remnanode/logs/access.log.1 "\$PENDING_DIR/access-${PREFIX}-\${TIMESTAMP}.txt"
            chmod 644 "\$PENDING_DIR/access-${PREFIX}-\${TIMESTAMP}.txt"
        fi
    endscript
}
EOF

LOGROTATE_ERROR="/etc/logrotate.d/remnanode-xray-error"
cat > "$LOGROTATE_ERROR" <<EOF
/opt/remnanode/logs/error.log {
    size 46M
    rotate 1
    copytruncate
    nocompress
    notifempty
    create 0644 root root
    postrotate
        if [[ -f "/opt/remnanode/logs/error.log.1" ]]; then
            TIMESTAMP=\$(date +%Y%m%d-%H%M%S)
            PENDING_DIR="/tmp/xray-logs-pending"
            mkdir -p "\$PENDING_DIR"
            mv /opt/remnanode/logs/error.log.1 "\$PENDING_DIR/error-${PREFIX}-\${TIMESTAMP}.txt"
            chmod 644 "\$PENDING_DIR/error-${PREFIX}-\${TIMESTAMP}.txt"
        fi
    endscript
}
EOF

# --- Скрипт автоматической отправки (с возвратом кода ошибки) ---
SEND_SCRIPT="/usr/local/bin/send-xray-logs.sh"
cat > "$SEND_SCRIPT" <<'EOF'
#!/bin/bash
set -o pipefail
set -e

BOT_TOKEN="<TOKEN>"
CHAT_ID="<CHAT_ID>"
PREFIX="<PREFIX>"
LOG_DIR="/opt/remnanode/logs"
PENDING_DIR="/tmp/xray-logs-pending"
LOGROTATE_ACCESS="/etc/logrotate.d/remnanode-xray-access"
LOGROTATE_ERROR="/etc/logrotate.d/remnanode-xray-error"
MAX_SIZE_MB=46
MAX_ATTEMPTS=3
TIMEOUT=10

mkdir -p "$PENDING_DIR"

# --- Функция проверки размера файла и ротации ---
rotate_if_needed() {
    local file="$1"
    local conf="$2"
    if [[ ! -f "$file" ]]; then
        return 0
    fi
    local size=$(stat -c%s "$file" 2>/dev/null || echo 0)
    local max=$((MAX_SIZE_MB * 1024 * 1024))
    if [ $size -ge $max ]; then
        echo "[*] Файл $file достиг $(($size/1024/1024)) МБ, выполняем ротацию..."
        if logrotate -f "$conf" 2>/dev/null; then
            echo "[✓] Ротация выполнена для $file"
        else
            echo "[!] Ошибка ротации для $file"
        fi
    fi
}

rotate_if_needed "$LOG_DIR/access.log" "$LOGROTATE_ACCESS"
rotate_if_needed "$LOG_DIR/error.log"   "$LOGROTATE_ERROR"

# --- Обработка очереди отправки ---
send_file() {
    local file="$1"
    local chat_id="$2"
    local token="$3"
    curl -s --max-time $TIMEOUT -F "chat_id=$chat_id" -F "document=@$file" \
        "https://api.telegram.org/bot$token/sendDocument" > /dev/null
    return $?
}

files=($(ls -1t "$PENDING_DIR"/*.txt 2>/dev/null | tac))
if [ ${#files[@]} -eq 0 ]; then
    echo "[*] Очередь пуста."
    exit 0
fi

for file in "${files[@]}"; do
    echo "[*] Обработка файла: $(basename "$file")"
    success=0
    for ((i=1; i<=MAX_ATTEMPTS; i++)); do
        if send_file "$file" "$CHAT_ID" "$BOT_TOKEN"; then
            echo "[✓] Файл отправлен (попытка $i)."
            rm -f "$file"
            success=1
            break
        else
            echo "[!] Не удалось отправить (попытка $i)."
            if [ $i -lt $MAX_ATTEMPTS ]; then
                sleep 10
            fi
        fi
    done
    if [ $success -eq 0 ]; then
        echo "[!] Не удалось отправить файл после $MAX_ATTEMPTS попыток. Оставляем в очереди."
        # Прерываем обработку следующих файлов
        break
    fi
done

# --- Если после обработки в очереди остались файлы, возвращаем ошибку ---
if [ -n "$(ls -A "$PENDING_DIR" 2>/dev/null)" ]; then
    echo "[!] В очереди остались неотправленные файлы. Возвращаем ошибку."
    exit 1
fi
exit 0
EOF

sed -i "s|<TOKEN>|$BOT_TOKEN|g" "$SEND_SCRIPT"
sed -i "s|<CHAT_ID>|$CHAT_ID|g" "$SEND_SCRIPT"
sed -i "s|<PREFIX>|$PREFIX|g" "$SEND_SCRIPT"
chmod +x "$SEND_SCRIPT"

# --- Добавляем cron (каждые 2 минуты) ---
CRON_JOB="*/2 * * * * $SEND_SCRIPT >/dev/null 2>&1"
(crontab -l 2>/dev/null | grep -v "$SEND_SCRIPT"; echo "$CRON_JOB") | crontab -
echo "[✓] Cron-задание добавлено (проверка размера и отправка каждые 2 минуты)."

# --- Скрипт ручной отправки (отправка access и error по отдельности, без очистки) ---
SEND_NOW_SCRIPT="/usr/local/bin/send-xray-logs-now.sh"
cat > "$SEND_NOW_SCRIPT" <<'EOF'
#!/bin/bash
set -o pipefail
set -e

BOT_TOKEN="<TOKEN>"
CHAT_ID="<CHAT_ID>"
PREFIX="<PREFIX>"
LOG_DIR="/opt/remnanode/logs"
TEMP_DIR="/tmp/xray-logs-now"
mkdir -p "$TEMP_DIR"

send_with_retry() {
    local file="$1"
    local chat_id="$2"
    local token="$3"
    local max_attempts=3
    local timeout=10
    for ((i=1; i<=max_attempts; i++)); do
        if curl -s --max-time $timeout -F "chat_id=$chat_id" -F "document=@$file" \
            "https://api.telegram.org/bot$token/sendDocument" > /dev/null; then
            echo "[✓] Файл $(basename "$file") отправлен (попытка $i)."
            return 0
        else
            echo "[!] Ошибка отправки $(basename "$file") (попытка $i)."
            if [ $i -lt $max_attempts ]; then
                sleep 10
            fi
        fi
    done
    echo "[!] Не удалось отправить файл $(basename "$file") после $max_attempts попыток."
    return 1
}

send_one() {
    local src="$1"
    local name="$2"
    if [[ ! -f "$src" ]]; then
        echo "[!] Файл $src не существует, пропускаем."
        return 0
    fi
    if [[ ! -s "$src" ]]; then
        echo "[*] Файл $src пуст, пропускаем."
        return 0
    fi
    local dst="$TEMP_DIR/${name}-${PREFIX}-$(date +%Y%m%d-%H%M%S).txt"
    cp "$src" "$dst"
    echo "[*] Отправка $name..."
    send_with_retry "$dst" "$CHAT_ID" "$BOT_TOKEN"
    local ret=$?
    rm -f "$dst"
    return $ret
}

failed=0
send_one "$LOG_DIR/access.log" "access" || failed=1
send_one "$LOG_DIR/error.log"  "error"  || failed=1

if [ $failed -ne 0 ]; then
    echo "[×] Ошибка при ручной отправке логов."
    exit 1
fi

echo "[✓] Ручная отправка завершена (логи не очищены)."
EOF

sed -i "s|<TOKEN>|$BOT_TOKEN|g" "$SEND_NOW_SCRIPT"
sed -i "s|<CHAT_ID>|$CHAT_ID|g" "$SEND_NOW_SCRIPT"
sed -i "s|<PREFIX>|$PREFIX|g" "$SEND_NOW_SCRIPT"
chmod +x "$SEND_NOW_SCRIPT"

# --- Запускаем один раз ---
$SEND_SCRIPT || true

# --- Снимаем trap после успешного выполнения ---
trap - INT TERM

echo ""
echo "[✓] Настройка отправки логов в Telegram завершена."
echo "[*] Токен: $BOT_TOKEN"
echo "[*] Chat ID: $CHAT_ID"
echo "[*] Префикс: $PREFIX"
echo "[*] Ротация access.log и error.log по отдельности при 46 МБ"
echo "[*] Проверка размера и отправка из очереди каждые 2 минуты"
echo "[*] Логи внутри контейнера: /var/log/xray"
echo "[*] Скрипт автоматической отправки: $SEND_SCRIPT"
echo "[*] Скрипт ручной отправки: $SEND_NOW_SCRIPT"
sleep 2
exit 0
