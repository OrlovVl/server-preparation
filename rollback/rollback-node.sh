#!/bin/bash
set -o pipefail
set -e

# --- Проверка прав root ---
if [ "$EUID" -ne 0 ]; then
    echo "[×] Запускайте от root."
    exit 1
fi

trap 'echo ""; echo "[!] Прервано. Откат может быть неполным."; exit 1' INT TERM

# --- Проверка Docker ---
if ! command -v docker &> /dev/null; then
    echo "[!] Docker не установлен."
    exit 1
fi

# --- Определение команды docker compose ---
if docker compose version &> /dev/null; then
    DOCKER_COMPOSE="docker compose"
elif command -v docker-compose &> /dev/null; then
    DOCKER_COMPOSE="docker-compose"
else
    echo "[!] docker compose (или docker-compose) не установлен."
    exit 1
fi

# --- Проверка существования рабочей директории ---
if [ ! -d "/opt/remnanode" ]; then
    echo "[!] Директория /opt/remnanode не существует. Откат не требуется."
    exit 0
fi

cd /opt/remnanode

# --- Остановка через docker compose ---
if [ -f "docker-compose.yml" ]; then
    echo "[*] Останавливаем и удаляем контейнеры..."
    $DOCKER_COMPOSE down
    echo "[✓] Контейнеры остановлены и удалены."
else
    # Если compose-файла нет, но контейнер остался – удаляем вручную
    if docker ps -a --format '{{.Names}}' | grep -q "^remnanode$"; then
        echo "[*] docker-compose.yml не найден, удаляем контейнер вручную..."
        docker stop remnanode || true
        docker rm remnanode || true
        echo "[✓] Контейнер удалён."
    else
        echo "[*] Контейнер remnanode не найден."
    fi
fi

# --- Удаление docker-compose.yml ---
if [ -f "docker-compose.yml" ]; then
    echo "[*] Удаляем docker-compose.yml..."
    rm -f docker-compose.yml
    echo "[✓] docker-compose.yml удалён."
fi

# --- Проверка содержимого папки ---
CONTENT=$(ls -A . 2>/dev/null || echo "")
if [ -z "$CONTENT" ]; then
    echo "[*] Папка /opt/remnanode пуста, удаляем её..."
    cd / && rm -rf /opt/remnanode
    echo "[✓] Готово, папка /opt/remnanode удалена."
else
    echo "[!] В папке /opt/remnanode остались файлы/каталоги, не созданные данным скриптом:"
    echo "    $CONTENT"
    echo "[!] Папка не удалена, чтобы не повредить сторонние файлы."
fi

echo ""
echo "[✓] Откат завершён."
exit 0
