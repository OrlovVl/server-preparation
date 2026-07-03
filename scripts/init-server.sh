#!/bin/bash
set -e

echo "=== Базовая подготовка сервера (переустановка Docker и Compose) ==="

if [ "$EUID" -ne 0 ]; then
  echo "[×] Запускайте от root."
  exit 1
fi

# --- Функция для безопасного выполнения команды с выводом статуса ---
safe_run() {
  local cmd="$1"
  local desc="$2"
  echo -n "[*] $desc... "
  if eval "$cmd" &>/dev/null; then
    echo "[✓]"
  else
    echo "[!] Не удалось выполнить (пропускаем)"
  fi
}

# --- 0. Обновление списка пакетов и установка curl ---
echo "[*] Обновляем список пакетов и устанавливаем curl..."
apt-get update
if ! command -v curl &> /dev/null; then
  apt-get install -y curl
else
  echo "  - curl уже установлен."
fi

# --- 1. Остановка всех служб Docker ---
echo "[*] Останавливаем все службы Docker..."
systemctl stop docker.service 2>/dev/null || true
systemctl stop docker.socket 2>/dev/null || true
systemctl stop containerd 2>/dev/null || true

# --- 2. Удаление всех пакетов Docker и Compose (включая плагины) ---
echo "[*] Удаляем существующие пакеты Docker и Compose..."
PKGS="docker.io docker-ce docker-engine docker-ce-cli containerd.io docker-ce-rootless-extras docker-buildx-plugin docker-compose-plugin"
for pkg in $PKGS; do
  # Безопасная проверка для режима set -e (добавлен || false)
  if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii " || false; then
    echo "  - Полностью вычищаем (purge) $pkg..."
    apt-get purge -y "$pkg"
  fi
done

safe_run "apt-get autoremove -y --purge" "Автоудаление зависимостей"

# --- 3. Удаление старых ручных бинарников Compose ---
echo "[*] Удаляем старые бинарники docker-compose (если есть)..."
rm -f /usr/local/bin/docker-compose
rm -f /usr/bin/docker-compose
rm -rf ~/.docker/cli-plugins/docker-compose

# --- 4. Очистка остаточных файлов (без удаления /var/lib/docker) ---
echo "[*] Бекапим/удаляем остаточные конфигурационные файлы (кроме данных)..."
if [ -f /etc/docker/daemon.json ]; then
  mv /etc/docker/daemon.json /etc/docker/daemon.json.bak
  echo "  - Старый daemon.json сохранен как daemon.json.bak"
fi
rm -rf /etc/docker/*.key /etc/docker/*.crt 2>/dev/null || true

# Удаляем сетевой интерфейс docker0, если он висит
if ip link show docker0 &>/dev/null; then
    echo "  - Сбрасываем старый сетевой мост docker0..."
    ip link set dev docker0 down 2>/dev/null || true
    ip link delete docker0 2>/dev/null || true
fi

echo "[✓] Система очищена от старого Docker, но данные (volumes) сохранены."

# --- 5. Обновление системы (после удаления Docker) ---
echo "[*] Обновляем систему (пакеты, ядро, зависимости)..."
safe_run "apt-get update" "Обновление списка пакетов"
safe_run "apt-get full-upgrade -y" "Полное обновление системы"
safe_run "apt-get autoremove -y" "Удаление ненужных пакетов после обновления"
safe_run "apt-get clean" "Очистка кэша apt"

# --- 6. Установка Docker через официальный скрипт ---
echo "[*] Устанавливаем Docker через официальный скрипт..."
if curl -fsSL https://get.docker.com | sh; then
  echo "[✓] Docker установлен успешно."
else
  echo "[×] Ошибка установки Docker. Прерываем выполнение."
  exit 1
fi

# --- 7. Запуск и включение Docker (на случай, если скрипт не запустил) ---
echo "[*] Проверяем запуск службы Docker..."
systemctl start docker || true
systemctl enable docker || true

# --- 8. Проверка работоспособности Docker ---
echo "[*] Проверяем работу Docker (запуск hello-world)..."
if docker run --rm hello-world >/dev/null 2>&1; then
  echo "[✓] Docker работает корректно."
else
  echo "[×] Docker не может запускать контейнеры. Проверьте настройки."
  exit 1
fi

# --- 9. Проверка и установка docker-compose (если отсутствует) ---
echo "[*] Проверяем наличие docker compose..."
if docker compose version &>/dev/null; then
  echo "[✓] docker compose (современный плагин V2) уже установлен скриптом Docker."
elif command -v docker-compose &>/dev/null; then
  echo "[✓] Найдена старая версия docker-compose (бинарник)."
else
  echo "[!] Предупреждение: Скрипт Docker не установил плагин Compose автоматически."
  echo "[*] Пробуем поставить docker-compose бинарник вручную с GitHub..."
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  ARCH=$(uname -m)
  URL="https://github.com/docker/compose/releases/latest/download/docker-compose-${OS}-${ARCH}"
  if curl -L "$URL" -o /usr/local/bin/docker-compose 2>/dev/null; then
    chmod +x /usr/local/bin/docker-compose
    echo "[✓] docker-compose успешно установлен вручную в /usr/local/bin/."
  else
    echo "[×] Не удалось установить docker compose автоматически. Требуется ручная настройка."
    exit 1
  fi
fi

# --- 10. Финальная проверка обеих команд ---
echo ""
echo "=== ФИНАЛЬНЫЙ СТАТУС СИСТЕМЫ ==="
docker --version

if docker compose version &>/dev/null; then
  echo -n "Docker Compose: " && docker compose version
elif command -v docker-compose &>/dev/null; then
  echo -n "Docker Compose (Legacy): " && docker-compose --version
fi

echo ""
echo "[✓] Базовая подготовка сервера завершена."
echo "[*] Контейнеры и Volumes из /var/lib/docker не пострадали."
exit 0
