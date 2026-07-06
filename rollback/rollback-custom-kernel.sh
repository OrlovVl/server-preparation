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
sed -i "\|$MOUNT_LINE|d" "$COMPOSE_FILE"

# --- Проверка и удаление пустой секции volumes (безопасно) ---
# Используем awk, чтобы удалить блок volumes, если в нём не осталось строк с "      - "
awk '
BEGIN { in_vol=0; block_start=0; lines=0; has_mount=0 }
{
    # Определяем отступы: если строка начинается с "    volumes:", начинаем блок
    if ($0 ~ /^    volumes:/) {
        in_vol=1
        block_start=NR
        lines=0
        has_mount=0
        # Сохраняем строку
        block[lines++] = $0
        next
    }
    # Если мы внутри блока volumes
    if (in_vol) {
        # Проверяем, не закончился ли блок (строка с отступом 2 пробела или меньше)
        if ($0 ~ /^  / && $0 !~ /^    /) {
            # Блок закончился, проверяем, были ли монтирования
            if (has_mount == 0) {
                # Блок пустой - пропускаем его вывод
                in_vol=0
                next
            } else {
                # Блок не пустой - выводим сохранённые строки
                for (i=0; i<lines; i++) print block[i]
                in_vol=0
                # Печатаем текущую строку (она уже не принадлежит блоку)
                print $0
                next
            }
        }
        # Строка внутри блока
        block[lines++] = $0
        if ($0 ~ /^      - /) has_mount=1
        next
    }
    # Если не в блоке, печатаем строку
    print $0
}
END {
    # Если блок остался открытым до конца файла
    if (in_vol) {
        if (has_mount == 0) {
            # Пустой блок в конце файла - не выводим
            # Ничего не делаем
        } else {
            for (i=0; i<lines; i++) print block[i]
        }
    }
}
' "$COMPOSE_FILE" > "$COMPOSE_FILE.tmp" && mv "$COMPOSE_FILE.tmp" "$COMPOSE_FILE"

# Проверка синтаксиса
if ! $DOCKER_COMPOSE config; then
    echo "[×] Ошибка в docker-compose.yml после изменений. Восстанавливаем бэкап..."
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
        echo "[!] Папка не удалена, чтобы не повредить другие данные."
    fi
fi

# Перезапускаем контейнер
echo "[*] Запускаем remnanode без кастомного xray..."
$DOCKER_COMPOSE up -d

sleep 8

echo "[*] Последние 50 строк логов:"
$DOCKER_COMPOSE logs --tail=50

echo ""
echo "[✓] Готово, откат кастомного ядра выполнен."
echo "[*] Контейнер перезапущен с оригинальным xray."
echo "================================================================================"
exit 0
