#!/bin/bash
set -o pipefail
set -e

if [ "$EUID" -ne 0 ]; then
    echo "[×] Запускайте от root."
    exit 1
fi

trap 'echo ""; echo "[!] Прервано. Откат может быть неполным."; exit 1' INT TERM

# Проверка Docker
if ! command -v docker &> /dev/null; then
    echo "[!] Docker не установлен."
    exit 1
fi

# Определяем команду docker compose
if docker compose version &> /dev/null; then
    DOCKER_COMPOSE="docker compose"
elif command -v docker-compose &> /dev/null; then
    DOCKER_COMPOSE="docker-compose"
else
    echo "[!] docker compose (или docker-compose) не установлен."
    exit 1
fi

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

# Проверка наличия /opt/remnanode и docker-compose.yml
if [[ ! -d "/opt/remnanode" || ! -f "/opt/remnanode/docker-compose.yml" ]]; then
    echo "[!] /opt/remnanode/docker-compose.yml не найден. Откат не требуется."
    exit 0
fi

cd /opt/remnanode

COMPOSE_FILE="docker-compose.yml"
MOUNT_LINE="      - /var/lib/remnanode/xray:/usr/local/bin/xray:ro"

if ! grep -q "$MOUNT_LINE" "$COMPOSE_FILE"; then
    echo "[✓] Монтирование xray не найдено. Откат не требуется."
    exit 0
fi

echo "[*] Обнаружено монтирование xray. Выполняем откат..."

# Останавливаем контейнер
echo "[*] Останавливаем remnanode..."
$DOCKER_COMPOSE down

# Удаляем строку монтирования
echo "[*] Удаляем монтирование из docker-compose.yml..."
cp "$COMPOSE_FILE" "$COMPOSE_FILE.bak"

MOUNT_LINE="/var/lib/remnanode/xray:/usr/local/bin/xray:ro"

# Удаляем конкретное монтирование из списка volumes
yq eval "del(.services.remnanode.volumes[] | select(. == \"$MOUNT_LINE\"))" -i "$COMPOSE_FILE"

# Если список volumes стал пустым, удаляем всю секцию volumes
VOLUMES_COUNT=$(yq eval '.services.remnanode.volumes | length' "$COMPOSE_FILE")
if [[ "$VOLUMES_COUNT" -eq 0 ]]; then
    yq eval 'del(.services.remnanode.volumes)' -i "$COMPOSE_FILE"
    echo "[✓] Секция volumes была пустой и удалена."
fi

# Проверка синтаксиса
if ! $DOCKER_COMPOSE config >/dev/null 2>&1; then
    echo "[×] Ошибка в docker-compose.yml после удаления монтирования. Восстанавливаем бэкап..."
    mv "$COMPOSE_FILE.bak" "$COMPOSE_FILE"
    exit 1
fi
rm -f "$COMPOSE_FILE.bak"

# Удаляем бинарник xray
XRAY_BIN="/var/lib/remnanode/xray"
if [[ -f "$XRAY_BIN" ]]; then
    echo "[*] Удаляем $XRAY_BIN..."
    rm -f "$XRAY_BIN"
fi

# Проверяем, пуста ли папка /var/lib/remnanode
if [[ -d "/var/lib/remnanode" ]]; then
    CONTENT=$(ls -A /var/lib/remnanode 2>/dev/null || echo "")
    if [[ -z "$CONTENT" ]]; then
        echo "[*] Папка /var/lib/remnanode пуста, удаляем..."
        rm -rf /var/lib/remnanode
    else
        echo "[!] В папке /var/lib/remnanode остались файлы:"
        echo "    $CONTENT"
        echo "[!] Папка не удалена, чтобы не повредить стороние данные."
    fi
fi

# Перезапускаем контейнер
echo "[*] Запускаем remnanode без кастомного xray..."
$DOCKER_COMPOSE up -d

# --- Вывод логов remnanode ---
echo "[*] Просмотр логов контейнера remnanode (15 секунд)..."
timeout 15 $DOCKER_COMPOSE -f /opt/remnanode/docker-compose.yml logs -f || true
echo "[*] Продолжаем выполнение..."

echo ""
echo "[✓] Готово, откат кастомного ядра выполнен."
echo "[*] Контейнер перезапущен с оригинальным xray."
echo "================================================================================"
exit 0
