#!/bin/bash
set -o pipefail
set -e

if [ "$EUID" -ne 0 ]; then
    echo "[×] Запускайте от root."
    exit 1
fi

# Функция очистки при прерывании
cleanup_custom() {
    echo ""
    echo "[!] Выполнение прервано. Откатываем изменения..."

    # Удаляем временный ZIP-файл
    if [[ -f "/tmp/Xray-linux-64.zip" ]]; then
        echo "[*] Удаляем /tmp/Xray-linux-64.zip"
        rm -f /tmp/Xray-linux-64.zip
    fi

    # Удаляем бинарник xray, если есть
    if [[ -f "/var/lib/remnanode/xray" ]]; then
        echo "[*] Удаляем /var/lib/remnanode/xray"
        rm -f /var/lib/remnanode/xray
    fi

    # Удаляем пустую папку /var/lib/remnanode, если она пуста
    if [[ -d "/var/lib/remnanode" ]] && [[ -z "$(ls -A /var/lib/remnanode 2>/dev/null)" ]]; then
        echo "[*] Удаляем пустую папку /var/lib/remnanode"
        rmdir /var/lib/remnanode
    fi

    # Откатываем добавленную секцию volume в docker-compose.yml
    if [[ -f "/opt/remnanode/docker-compose.yml" ]]; then
        COMPOSE_FILE="/opt/remnanode/docker-compose.yml"
        MOUNT_LINE="      - /var/lib/remnanode/xray:/usr/local/bin/xray:ro"
        if grep -q "$MOUNT_LINE" "$COMPOSE_FILE"; then
            echo "[*] Удаляем монтирование xray из $COMPOSE_FILE"
            sed -i "\|$MOUNT_LINE|d" "$COMPOSE_FILE"
        fi
    fi

    # Перезапускаем контейнер remnanode (если он существовал)
    if [[ -f "/opt/remnanode/docker-compose.yml" ]]; then
        cd /opt/remnanode
        echo "[*] Перезапускаем remnanode без кастомного xray..."
        $DOCKER_COMPOSE up -d || true
        cd /
    fi

    echo "[✓] Очистка завершена."
    exit 1
}
trap cleanup_custom INT TERM

# Проверка Docker
if ! command -v docker &> /dev/null; then
    echo "[!] Docker не установлен. Установите его: curl -fsSL https://get.docker.com | sh"
    exit 1
fi

# Определяем команду docker compose (плагин или бинарник)
if docker compose version &> /dev/null; then
    DOCKER_COMPOSE="docker compose"
elif command -v docker-compose &> /dev/null; then
    DOCKER_COMPOSE="docker-compose"
else
    echo "[!] docker compose (или docker-compose) не установлен. Установите отдельно."
    exit 1
fi

# Установка пакетов
for pkg in wget unzip; do
    if ! command -v "$pkg" &> /dev/null; then
        echo "[*] Устанавливаем $pkg..."
        apt-get update
        apt-get install -y "$pkg"
    fi
done

# Парсинг аргументов
KERNEL_VERSION=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --version|-v)
            KERNEL_VERSION="$2"
            shift 2
            ;;
        --help|-h)
            echo "Использование: $0 --version <версия>"
            echo "Пример: $0 --version 26.6.27"
            exit 0
            ;;
        *)
            echo "[×] Неизвестный параметр: $1"
            exit 1
            ;;
    esac
done

if [[ -z "$KERNEL_VERSION" ]]; then
    echo "[×] Укажите версию: --version 26.6.27"
    exit 1
fi

# Проверка наличия /opt/remnanode и docker-compose.yml
if [[ ! -d "/opt/remnanode" || ! -f "/opt/remnanode/docker-compose.yml" ]]; then
    echo "[×] /opt/remnanode/docker-compose.yml не найден. Сначала выполните setup-node.sh."
    exit 1
fi

cd /opt/remnanode

# Остановка контейнера
echo "[*] Останавливаем remnanode..."
$DOCKER_COMPOSE down

# Скачивание Xray
URL="https://github.com/XTLS/Xray-core/releases/download/v${KERNEL_VERSION}/Xray-linux-64.zip"
ZIP_FILE="/tmp/Xray-linux-64.zip"
XRAY_BIN="/var/lib/remnanode/xray"

echo "[*] Скачиваем Xray-core ${KERNEL_VERSION}..."
wget --tries=5 --waitretry=10 --show-progress -O "$ZIP_FILE" "$URL"

if [[ ! -s "$ZIP_FILE" ]]; then
    echo "[×] Ошибка: файл $ZIP_FILE пуст или не скачался."
    exit 1
fi

echo "[*] Распаковываем в /var/lib/remnanode..."
mkdir -p /var/lib/remnanode
unzip -o "$ZIP_FILE" xray -d /var/lib/remnanode/

if [[ ! -f "$XRAY_BIN" ]]; then
    echo "[×] Ошибка: бинарник xray не найден после распаковки."
    exit 1
fi

chmod +x "$XRAY_BIN"
rm -f "$ZIP_FILE"

# --- Работа с volume (без yq) ---
COMPOSE_FILE="docker-compose.yml"
MOUNT_LINE="      - /var/lib/remnanode/xray:/usr/local/bin/xray:ro"

echo "[*] Проверяем наличие монтирования xray..."

if grep -q "$MOUNT_LINE" "$COMPOSE_FILE"; then
    echo "[✓] Монтирование уже присутствует. Пропускаем."
else
    echo "[*] Добавляем монтирование в docker-compose.yml..."

    # Создаём бэкап
    cp "$COMPOSE_FILE" "$COMPOSE_FILE.bak"

    if grep -q "^    volumes:" "$COMPOSE_FILE"; then
        # Секция volumes уже есть – добавляем строку в конец блока volumes
        # Ищем блок от "    volumes:" до следующей строки с отступом 2 пробела (закрытие секции)
        sed -i "/^    volumes:/,/^  / {
            /^  / i\\
$MOUNT_LINE
        }" "$COMPOSE_FILE"
    else
        # Секции volumes нет – дописываем в конец файла
        echo "    volumes:" >> "$COMPOSE_FILE"
        echo "$MOUNT_LINE" >> "$COMPOSE_FILE"
    fi

    # Проверяем синтаксис compose-файла
    if ! $DOCKER_COMPOSE config; then
        echo "[×] Ошибка в docker-compose.yml после добавления volume. Восстанавливаем бэкап..."
        mv "$COMPOSE_FILE.bak" "$COMPOSE_FILE"
        exit 1
    fi
    rm -f "$COMPOSE_FILE.bak"

    echo "[✓] Монтирование добавлено."
fi

# Запуск контейнера
echo "[*] Запускаем remnanode..."
$DOCKER_COMPOSE up -d

# --- Вывод логов remnanode ---
echo "[*] Просмотр логов контейнера remnanode (15 секунд)..."
timeout 15 $DOCKER_COMPOSE -f /opt/remnanode/docker-compose.yml logs -f || true
echo "[*] Продолжаем выполнение..."

# --- Снимаем trap после успешного выполнения ---
trap - INT TERM

echo ""
echo "[✓] Готово, Xray-core ${KERNEL_VERSION} установлен."
echo "[*] Проверьте выведенные логи для подтверждения корректности работы."
echo "[*] Проверка версии: docker exec remnanode /usr/local/bin/xray version"
echo "================================================================================"
sleep 2
exit 0
