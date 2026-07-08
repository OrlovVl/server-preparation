#!/bin/bash
set -o pipefail
set -e

# --- Проверка прав root ---
if [ "$EUID" -ne 0 ]; then
    echo "[×] Запускайте от root."
    exit 1
fi

# --- Проверка Docker ---
if ! command -v docker &> /dev/null; then
    echo "[!] Docker не установлен. Установите его (например, через curl -fsSL https://get.docker.com | sh)."
    exit 1
fi

# --- Определение команды docker compose (предпочтение без дефиса) ---
if docker compose version &> /dev/null; then
    DOCKER_COMPOSE="docker compose"
elif command -v docker-compose &> /dev/null; then
    DOCKER_COMPOSE="docker-compose"
else
    echo "[!] docker compose (или docker-compose) не установлен. Установите отдельно."
    exit 1
fi

# --- Парсинг аргументов ---
SECRET_KEY=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --secret-key)
            SECRET_KEY="$2"
            shift 2
            ;;
        --help|-h)
            echo "Использование: $0 --secret-key 'ваш_секретный_ключ'"
            echo ""
            echo "Обязательные параметры:"
            echo "  --secret-key   Секретный ключ для подключения к ноде"
            echo ""
            echo "Пример:"
            echo "  $0 --secret-key 'my-super-secret-key-123'"
            exit 0
            ;;
        *)
            echo "[×] Неизвестный параметр: $1"
            echo "Используйте --help для справки."
            exit 1
            ;;
    esac
done

if [[ -z "$SECRET_KEY" ]]; then
    echo "[×] Не указан SECRET_KEY."
    echo "Использование: $0 --secret-key 'ваш_секретный_ключ'"
    exit 1
fi

# --- Перехват сигналов (Ctrl+C, завершение) ---
cleanup() {
    echo ""
    echo "[!] Получен сигнал прерывания. Выполняем очистку..."
    if docker ps --format '{{.Names}}' | grep -q "^remnanode$"; then
        echo "[*] Контейнер уже запущен, оставляем его работающим."
    else
        echo "[*] Контейнер ещё не запущен, останавливаем и удаляем созданные ресурсы..."
        # Останавливаем и удаляем контейнер через docker compose, если есть compose-файл
        if [ -f "/opt/remnanode/docker-compose.yml" ]; then
            cd /opt/remnanode && $DOCKER_COMPOSE down || true
        fi
        # Удаляем docker-compose.yml, если он существует
        if [ -f "/opt/remnanode/docker-compose.yml" ]; then
            rm -f /opt/remnanode/docker-compose.yml
        fi
        # Удаляем папку /opt/remnanode, если она пуста (проверяем, что она существует и внутри нет файлов)
        if [ -d "/opt/remnanode" ] && [ -z "$(ls -A /opt/remnanode 2>/dev/null)" ]; then
            rm -rf /opt/remnanode
        fi
        echo "[✓] Очистка выполнена."
    fi
    exit 1
}
trap cleanup INT TERM

# --- Проверка существующего контейнера ---
EXISTING_SECRET=""
if docker ps -a --format '{{.Names}}' | grep -q "^remnanode$"; then
    EXISTING_SECRET=$(docker inspect remnanode --format='{{index .Config.Env 1}}' 2>/dev/null | cut -d= -f2)
    if [[ "$EXISTING_SECRET" == "$SECRET_KEY" ]]; then
        echo "[✓] Контейнер remnanode уже существует с таким же SECRET_KEY. Пропускаем переустановку."
        echo "Для принудительной переустановки удалите контейнер вручную, запустите удаление ноды или измените SECRET_KEY."
        exit 0
    else
        echo "[!] Контейнер существует, но SECRET_KEY отличается. Удаляем старый контейнер и compose-файл..."
        docker stop remnanode || true
        docker rm remnanode || true
        rm -f /opt/remnanode/docker-compose.yml
    fi
fi

# --- Создание рабочей директории ---
echo "[*] Создаём /opt/remnanode..."
mkdir -p /opt/remnanode

# --- Создание docker-compose.yml ---
echo "[*] Генерируем docker-compose.yml..."
cat > /opt/remnanode/docker-compose.yml <<EOF
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      - NODE_PORT=2222
      - SECRET_KEY="${SECRET_KEY}"
EOF

# --- Запуск контейнера ---
cd /opt/remnanode
echo "[*] Запускаем контейнер (может занять время на скачивание образа)..."
$DOCKER_COMPOSE up -d

# --- Ожидание запуска контейнера с таймаутом и проверкой статуса ---
echo "[*] Ожидаем запуска контейнера remnanode (Ctrl+C для прерывания)..."
TIMEOUT=120
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
    STATUS=$(docker inspect --format='{{.State.Status}}' remnanode 2>/dev/null || echo "missing")
    if [ "$STATUS" = "running" ]; then
        echo ""
        echo "[✓] Контейнер remnanode успешно запущен."
        break
    elif [ "$STATUS" = "exited" ] || [ "$STATUS" = "dead" ]; then
        echo ""
        echo "[×] Контейнер завершился с ошибкой. Статус: $STATUS"
        echo "Логи контейнера:"
        docker logs remnanode --tail 20
        exit 1
    fi
    sleep 3
    ELAPSED=$((ELAPSED + 3))
    echo -n "."
done
if [ $ELAPSED -ge $TIMEOUT ]; then
    echo ""
    echo "[×] Таймаут ожидания запуска контейнера."
    docker logs remnanode --tail 20
    exit 1
fi

# --- Вывод логов remnanode ---
echo "[*] Просмотр логов контейнера remnanode (15 секунд)..."
timeout 15 $DOCKER_COMPOSE -f /opt/remnanode/docker-compose.yml logs -f || true
echo "[*] Продолжаем выполнение..."

# --- Снимаем trap после успешного выполнения ---
trap - INT TERM

# --- Итоговая информация ---
echo ""
echo "[✓] Готово"
echo "================================================================================"
echo "[*] Контейнер: remnanode"
echo "[*] Образ: remnawave/node:latest"
echo "[*] Порт: 2222 (network_mode: host)"
echo "[*] SECRET_KEY: ${SECRET_KEY}"
echo "[*] Статус: запущен и работает"
echo "[*] Логи: docker logs remnanode"
echo "[*] Остановка: $DOCKER_COMPOSE -f /opt/remnanode/docker-compose.yml down"
echo "================================================================================"
sleep 2
exit 0
