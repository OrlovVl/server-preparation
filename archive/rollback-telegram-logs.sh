#!/bin/bash
# сломанная отправка
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

# --- Определение docker compose ---
if docker compose version &> /dev/null; then
    DOCKER_COMPOSE="docker compose"
elif command -v docker-compose &> /dev/null; then
    DOCKER_COMPOSE="docker-compose"
else
    echo "[!] docker compose не установлен."
    exit 1
fi

# --- Проверяем наличие настройки ---
if [[ ! -f "/usr/local/bin/send-xray-logs.sh" ]]; then
    echo "[!] Настройка отправки логов не обнаружена. Откат не требуется."
    exit 0
fi

echo "[*] Откат отправки логов в Telegram..."

# --- 1. Отправляем логи из очереди (с ротацией при необходимости) ---
echo "[*] Отправляем логи из очереди..."
if ! /usr/local/bin/send-xray-logs.sh; then
    echo "[×] Не удалось отправить логи из очереди. Откат прерван. Повторите позже."
    exit 1
fi

# --- 2. Отправляем текущие логи (access.log и error.log) без очистки ---
echo "[*] Отправляем текущие логи..."
if ! /usr/local/bin/send-xray-logs-now.sh; then
    echo "[×] Не удалось отправить текущие логи. Откат прерван. Повторите позже."
    exit 1
fi

echo "[✓] Все логи успешно отправлены. Продолжаем удаление настроек."

# --- 3. Удаляем cron-задание ---
if crontab -l 2>/dev/null | grep -q "send-xray-logs.sh"; then
    crontab -l 2>/dev/null | grep -v "send-xray-logs.sh" | crontab -
    echo "[✓] Cron-задание удалено."
fi

# --- 4. Удаляем скрипты отправки ---
rm -f /usr/local/bin/send-xray-logs.sh
rm -f /usr/local/bin/send-xray-logs-now.sh
echo "[✓] Скрипты отправки удалены."

# --- 5. Удаляем папку с очередью ---
if [[ -d "/tmp/xray-logs-pending" ]]; then
    rm -rf /tmp/xray-logs-pending
    echo "[✓] Папка очереди удалена."
fi

# --- 6. Удаляем конфиги logrotate ---
for conf in /etc/logrotate.d/remnanode-xray-access /etc/logrotate.d/remnanode-xray-error; do
    if [[ -f "$conf" ]]; then
        rm -f "$conf"
        echo "[✓] Конфиг $conf удалён."
    fi
done

# --- 7. Удаляем монтирование из docker-compose.yml ---
COMPOSE_FILE="/opt/remnanode/docker-compose.yml"
if [[ -f "$COMPOSE_FILE" ]]; then
    if grep -q "/var/log/xray" "$COMPOSE_FILE"; then
        cp "$COMPOSE_FILE" "$COMPOSE_FILE.bak"

        # Удаляем только строку с монтированием логов
        sed -i "\|/var/log/xray|d" "$COMPOSE_FILE"

        # Проверяем, остались ли другие монтирования в секции volumes
        # Используем awk для точного определения, есть ли строки с "      - " внутри volumes
        HAS_OTHER_MOUNTS=$(awk '/^    volumes:/,/^  / { if ($0 ~ /^      - /) found=1 } END { print found }' "$COMPOSE_FILE")

        if [[ "$HAS_OTHER_MOUNTS" == "0" ]]; then
            # Нет других монтирований – удаляем всю секцию volumes
            sed -i '/^    volumes:/,/^  /d' "$COMPOSE_FILE"
            echo "[✓] Пустая секция volumes удалена."
        else
            echo "[✓] Другие монтирования сохранены."
        fi

        # Проверяем синтаксис
        if ! $DOCKER_COMPOSE -f "$COMPOSE_FILE" config >/dev/null 2>&1; then
            echo "[!] Ошибка в $COMPOSE_FILE после удаления монтирования. Восстанавливаем бэкап..."
            mv "$COMPOSE_FILE.bak" "$COMPOSE_FILE"
        else
            rm -f "$COMPOSE_FILE.bak"
            echo "[✓] Монтирование для логов удалено."
            # Перезапускаем remnanode только если контейнер существует
            if docker ps -a --format '{{.Names}}' | grep -q "^remnanode$"; then
                echo "[*] Перезапускаем remnanode..."
                $DOCKER_COMPOSE -f "$COMPOSE_FILE" down
                $DOCKER_COMPOSE -f "$COMPOSE_FILE" up -d
            fi
        fi
    else
        echo "[✓] Монтирование для логов не найдено."
    fi
fi

# --- 8. Удаляем папку с логами ---
if [[ -d "/opt/remnanode/logs" ]]; then
    echo "[*] Удаляем папку /opt/remnanode/logs и всё её содержимое..."
    rm -rf /opt/remnanode/logs
    echo "[✓] Папка /opt/remnanode/logs удалена."
fi

# --- Вывод логов remnanode ---
echo "[*] Просмотр логов контейнера remnanode (15 секунд)..."
timeout 15 $DOCKER_COMPOSE -f /opt/remnanode/docker-compose.yml logs -f || true
echo "[*] Продолжаем выполнение..."

echo "[✓] Откат отправки логов в Telegram завершён."
exit 0
