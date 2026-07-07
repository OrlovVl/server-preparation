#!/bin/bash
set -o pipefail
set -e

echo "=== Базовая подготовка сервера (переустановка Docker и Compose) ==="

if [ "$EUID" -ne 0 ]; then
  echo "[×] Запускайте от root."
  exit 1
fi

trap 'echo "[!] Прервано. Попытка отката..."; exit 1' INT TERM

# --- Функция для безопасного выполнения команды с выводом статуса ---
safe_run() {
  local cmd="$1"
  local desc="$2"
  echo -n "[*] $desc... "
  if eval "$cmd"; then
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
fi

# --- 1. Остановка всех служб Docker ---
echo "[*] Останавливаем все службы Docker..."
systemctl stop docker.service || true
systemctl stop docker.socket || true
systemctl stop containerd || true

# --- 2. Удаление всех пакетов Docker и Compose (включая плагины) ---
echo "[*] Удаляем существующие пакеты Docker и Compose..."
PKGS="docker.io docker-ce docker-engine docker-ce-cli containerd.io docker-ce-rootless-extras docker-buildx-plugin docker-compose-plugin"
for pkg in $PKGS; do
  # Безопасная проверка для режима set -e (добавлен || false)
  if dpkg -l "$pkg" | grep -q "^ii " || false; then
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
rm -rf /etc/docker/*.key /etc/docker/*.crt || true

# Удаляем сетевой интерфейс docker0, если он висит
if ip link show docker0; then
    echo "  - Сбрасываем старый сетевой мост docker0..."
    ip link set dev docker0 down || true
    ip link delete docker0 || true
fi

echo "[✓] Система очищена от старого Docker, но данные (volumes) сохранены."

# --- 5. Обновление системы (после удаления Docker) ---
echo "[*] Обновляем систему (пакеты, ядро, зависимости)..."
safe_run "apt-get full-upgrade -y" "Полное обновление системы"
safe_run "apt-get autoremove -y" "Удаление ненужных пакетов после обновления"
safe_run "apt-get clean" "Очистка кэша apt"

# --- 6. Установка Docker через официальный скрипт ---
echo "[*] Устанавливаем Docker через официальный скрипт..."
if curl -fL --retry 5 --retry-delay 10 https://get.docker.com | sh; then
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
if docker run --rm hello-world; then
  echo "[✓] Docker работает корректно."
else
  echo "[×] Docker не может запускать контейнеры. Проверьте настройки."
  exit 1
fi

# --- 9. Проверка и установка docker-compose (если отсутствует) ---
echo "[*] Проверяем наличие docker compose..."
if docker compose version; then
  echo "[✓] docker compose уже установлен скриптом Docker."
elif command -v docker-compose; then
  echo "[✓] Найдена старая версия docker-compose (бинарник)."
else
  echo "[!] Предупреждение: Скрипт Docker не установил плагин Compose автоматически."
  echo "[*] Пробуем поставить docker-compose бинарник вручную с GitHub..."
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  ARCH=$(uname -m)
  URL="https://github.com/docker/compose/releases/latest/download/docker-compose-${OS}-${ARCH}"
  if curl -L --retry 5 --retry-delay 10 "$URL" -o /usr/local/bin/docker-compose; then
    chmod +x /usr/local/bin/docker-compose
    echo "[✓] docker-compose успешно установлен вручную в /usr/local/bin/."
  else
    echo "[×] Не удалось установить docker compose автоматически. Требуется ручная настройка."
    exit 1
  fi
fi

# --- 10. Проверка обеих команд ---
echo ""
echo "=== Проверка успешной установки Docker и Docker Compose ==="
docker --version

if docker compose version; then
  echo -n "Docker Compose: " && docker compose version
elif command -v docker-compose; then
  echo -n "Docker Compose (Legacy): " && docker-compose --version
fi

# --- Снимаем trap после успешного выполнения ---
trap - INT TERM

echo ""
echo "[✓] Базовая подготовка сервера завершена."
echo "[*] Контейнеры и Volumes из /var/lib/docker не пострадали."
sleep 3
exit 0
