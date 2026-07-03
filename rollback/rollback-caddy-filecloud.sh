#!/bin/bash
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

# --- Определение команды docker compose ---
if docker compose version &> /dev/null; then
    DOCKER_COMPOSE="docker compose"
elif command -v docker-compose &> /dev/null; then
    DOCKER_COMPOSE="docker-compose"
else
    echo "[!] docker compose (или docker-compose) не установлен."
    exit 1
fi

# --- 1. Остановка и удаление контейнеров Caddy и FileCloud ---
CADDY_DIR="/opt/remnanode/caddy"
if [[ -d "$CADDY_DIR" && -f "$CADDY_DIR/docker-compose.yml" ]]; then
    echo "[*] Останавливаем и удаляем контейнеры Caddy и FileCloud..."
    cd "$CADDY_DIR"
    $DOCKER_COMPOSE down
    cd /
else
    echo "[!] Директория caddy или docker-compose.yml не найдены. Пропускаем остановку."
fi

# --- 2. Удаление папок caddy и filecloud ---
for dir in "$CADDY_DIR" "/opt/remnanode/filecloud"; do
    if [[ -d "$dir" ]]; then
        echo "[*] Удаляем $dir..."
        rm -rf "$dir"
        echo "[✓] $dir удалена."
    else
        echo "[!] $dir не найдена, пропускаем."
    fi
done

# --- 3. Удаление симлинков сертификатов ---
if [[ -L "/etc/ssl/certs/noctua.crt" ]]; then
    echo "[*] Удаляем симлинк /etc/ssl/certs/noctua.crt..."
    rm -f /etc/ssl/certs/noctua.crt
fi
if [[ -L "/etc/ssl/private/noctua.key" ]]; then
    echo "[*] Удаляем симлинк /etc/ssl/private/noctua.key..."
    rm -f /etc/ssl/private/noctua.key
fi

# --- 4. Удаление монтирования сертификатов из docker-compose.yml remnanode ---
REMNA_NODE_COMPOSE="/opt/remnanode/docker-compose.yml"
if [[ -f "$REMNA_NODE_COMPOSE" ]]; then
    echo "[*] Удаляем монтирование сертификатов из $REMNA_NODE_COMPOSE..."

    MOUNT_CERT="      - /etc/ssl/certs/noctua.crt:/etc/ssl/certs/noctua.crt:ro"
    MOUNT_KEY="      - /etc/ssl/private/noctua.key:/etc/ssl/private/noctua.key:ro"

    if grep -q "$MOUNT_CERT" "$REMNA_NODE_COMPOSE" || grep -q "$MOUNT_KEY" "$REMNA_NODE_COMPOSE"; then
        cp "$REMNA_NODE_COMPOSE" "$REMNA_NODE_COMPOSE.bak"

        # Удаляем строки монтирования
        sed -i "\|$MOUNT_CERT|d" "$REMNA_NODE_COMPOSE"
        sed -i "\|$MOUNT_KEY|d" "$REMNA_NODE_COMPOSE"

        # ---- Удаление пустой секции volumes ----
        awk '
        BEGIN { in_vol=0; lines=0; has_mount=0; block[100] }
        {
            if ($0 ~ /^    volumes:/) {
                in_vol=1
                lines=0
                has_mount=0
                block[lines++] = $0
                next
            }
            if (in_vol) {
                if ($0 ~ /^  / && $0 !~ /^    /) {
                    if (has_mount == 0) {
                        in_vol=0
                        next
                    } else {
                        for (i=0; i<lines; i++) print block[i]
                        in_vol=0
                        print $0
                        next
                    }
                }
                block[lines++] = $0
                if ($0 ~ /^      - /) has_mount=1
                next
            }
            print $0
        }
        END {
            if (in_vol && has_mount != 0) {
                for (i=0; i<lines; i++) print block[i]
            }
        }
        ' "$REMNA_NODE_COMPOSE" > "$REMNA_NODE_COMPOSE.tmp" && mv "$REMNA_NODE_COMPOSE.tmp" "$REMNA_NODE_COMPOSE"

        # Проверка синтаксиса
        if ! $DOCKER_COMPOSE -f "$REMNA_NODE_COMPOSE" config &> /dev/null; then
            echo "[×] Ошибка в $REMNA_NODE_COMPOSE после изменений. Восстанавливаем бэкап..."
            mv "$REMNA_NODE_COMPOSE.bak" "$REMNA_NODE_COMPOSE"
            exit 1
        fi
        rm -f "$REMNA_NODE_COMPOSE.bak"

        echo "[✓] Монтирование сертификатов удалено."

        # Перезапуск remnanode
        echo "[*] Перезапускаем remnanode..."
        $DOCKER_COMPOSE -f "$REMNA_NODE_COMPOSE" down
        $DOCKER_COMPOSE -f "$REMNA_NODE_COMPOSE" up -d
    else
        echo "[✓] Монтирование сертификатов в remnanode не найдено."
    fi
else
    echo "[!] /opt/remnanode/docker-compose.yml не найден. Пропускаем."
fi

echo ""
echo "[✓] Откат Caddy и FileCloud завершён."
echo "================================================================================"
echo "[*] Контейнеры остановлены и удалены."
echo "[*] Папки /opt/remnanode/caddy и /opt/remnanode/filecloud удалены."
echo "[*] Симлинки сертификатов удалены."
echo "[*] Монтирование сертификатов из remnanode удалено (если было)."
echo "[*] remnanode перезапущен (если существовал)."
echo "================================================================================"
exit 0
