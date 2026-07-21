#!/bin/bash
set -o pipefail
set -e

if [ "$EUID" -ne 0 ]; then
    echo "[×] Запускайте от root."
    exit 1
fi

# --- Проверка Docker ---
if ! command -v docker &> /dev/null; then
    echo "[!] Docker не установлен."
    exit 1
fi

if docker compose version &> /dev/null; then
    DOCKER_COMPOSE="docker compose"
elif command -v docker-compose &> /dev/null; then
    DOCKER_COMPOSE="docker-compose"
else
    echo "[!] docker compose не установлен."
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

COMPOSE_FILE="/opt/remnanode/docker-compose.yml"
if [[ ! -f "$COMPOSE_FILE" ]]; then
    echo "[!] $COMPOSE_FILE не найден. Сначала выполните setup-node.sh."
    exit 1
fi

echo "[*] Настраиваем ротацию логов для remnanode..."

# --- Проверяем наличие блока logging ---
if [ "$(yq eval '.services.remnanode.logging' "$COMPOSE_FILE")" != "null" ]; then
    echo "[✓] Блок logging уже присутствует. Пропускаем добавление."
else
    echo "[*] Добавляем блок logging..."
    # Создаём бэкап перед изменением
    cp "$COMPOSE_FILE" "$COMPOSE_FILE.bak"
    yq eval '.services.remnanode.logging = {"driver": "json-file", "options": {"max-size": "10m", "max-file": "3"}}' -i "$COMPOSE_FILE"
fi

# --- Проверка синтаксиса ---
if ! $DOCKER_COMPOSE -f "$COMPOSE_FILE" config >/dev/null 2>&1; then
    echo "[×] Ошибка в compose-файле после изменений. Восстанавливаем из бэкапа..."
    if [[ -f "$COMPOSE_FILE.bak" ]]; then
        mv "$COMPOSE_FILE.bak" "$COMPOSE_FILE"
    fi
    exit 1
fi
rm -f "$COMPOSE_FILE.bak"

# --- Перезапуск контейнера ---
echo "[*] Перезапускаем remnanode для применения настроек..."
$DOCKER_COMPOSE -f "$COMPOSE_FILE" down
$DOCKER_COMPOSE -f "$COMPOSE_FILE" up -d

# --- Вывод логов remnanode ---
echo "[*] Просмотр логов контейнера remnanode (15 секунд)..."
timeout 15 $DOCKER_COMPOSE -f /opt/remnanode/docker-compose.yml logs -f || true
echo "[*] Продолжаем выполнение..."

echo ""
echo "[✓] Ротация логов настроена: max-size=10m, max-file=3"
sleep 2
exit 0
