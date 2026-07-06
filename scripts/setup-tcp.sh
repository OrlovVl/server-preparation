#!/bin/bash
set -o pipefail
set -e

echo "=== Настройка сервера (TCP-оптимизация) ==="

if [ "$EUID" -ne 0 ]; then
  echo "[×] Запускайте от root."
  exit 1
fi

# --- Директория бэкапов ---
BACKUP_BASE="/opt/remnanode/backups"
BACKUP_DIR="${BACKUP_BASE}/tcp"
ACTIVE_FILE="${BACKUP_BASE}/active"
ROLLBACK_URL_BASE="https://raw.githubusercontent.com/OrlovVl/server-preparation/refs/heads/main/rollback"

mkdir -p "$BACKUP_BASE"

# --- Функция загрузки и выполнения rollback-скрипта ---
run_rollback() {
  local profile="$1"
  local url="${ROLLBACK_URL_BASE}/rollback-${profile}.sh"
  echo "[*] Загружаем rollback-${profile}.sh с GitHub..."
  if curl -fsSL "$url" | bash -s; then
    echo "[✓] Откат '$profile' выполнен."
    return 0
  else
    echo "[!] Не удалось загрузить или выполнить rollback-${profile}.sh. Пробуем встроенный откат..."
    rollback_profile "$profile"
    return $?
  fi
}

# --- Функция проверки и переключения активного профиля ---
switch_profile() {
  local new_profile="$1"
  if [ -f "$ACTIVE_FILE" ]; then
    local current=$(cat "$ACTIVE_FILE")
    if [ "$current" != "$new_profile" ]; then
      echo "[*] Активен профиль '$current'. Выполняем его откат..."
      run_rollback "$current"
    else
      echo "[*] Уже активен профиль '$new_profile'. Продолжаем (бэкапы не пересоздаются)."
      return 0
    fi
  fi

  # Создаём бэкапы для нового профиля, если их ещё нет
  if [ ! -d "$BACKUP_DIR" ] || [ ! -f "${BACKUP_DIR}/.backup_created" ]; then
    echo "[*] Создаём бэкапы файлов для профиля '$new_profile'..."
    mkdir -p "$BACKUP_DIR"
    create_backups "$BACKUP_DIR"
    touch "${BACKUP_DIR}/.backup_created"
  else
    echo "[*] Бэкапы для '$new_profile' уже существуют."
  fi

  echo "$new_profile" > "$ACTIVE_FILE"
  echo "[✓] Активный профиль: $new_profile"
}

# --- Функция создания бэкапов (сохраняем состояние swap) ---
create_backups() {
  local dest="$1"
  local files=(
    "/etc/sysctl.conf"
    "/etc/default/ufw"
    "/etc/ufw/before.rules"
    "/etc/ufw/user.rules"
    "/etc/ufw/user6.rules"
    "/etc/security/limits.conf"
    "/etc/modules-load.d/modules.conf"
    "/etc/fstab"
  )
  for f in "${files[@]}"; do
    if [ -f "$f" ]; then
      local name=$(echo "$f" | sed 's/^\///; s/\//_/g')
      cp "$f" "${dest}/${name}"
      echo "  [✓] $f -> ${dest}/${name}"
    else
      echo "  [!] $f не существует, пропускаем."
    fi
  done

  # --- Сохраняем состояние swap ---
  local swap_info="${dest}/swap_info.txt"
  if [ -f /swapfile ]; then
    local size_bytes=$(stat -c%s /swapfile || echo 0)
    local size_mb=$((size_bytes / 1024 / 1024))
    echo "exists=yes" > "$swap_info"
    echo "size_mb=$size_mb" >> "$swap_info"
  else
    echo "exists=no" > "$swap_info"
    echo "size_mb=0" >> "$swap_info"
  fi

  # --- Сохраняем состояние ufw ---
  if ufw status | grep -q "Status: active"; then
    echo "active" > "${dest}/ufw_status.txt"
  else
    echo "inactive" > "${dest}/ufw_status.txt"
  fi

  # Сохраняем переданные порты
  echo "$TCP_PORTS" > "${dest}/tcp_ports.txt" || true
}

# --- Функция встроенного отката (если rollback-скрипт недоступен) ---
rollback_profile() {
  local profile="$1"
  local backup_dir="${BACKUP_BASE}/${profile}"
  if [ ! -d "$backup_dir" ]; then
    echo "[!] Бэкапы для '$profile' не найдены. Пропускаем."
    return 0
  fi
  echo "[*] Восстанавливаем бэкапы для '$profile'..."

  # Восстанавливаем файлы (кроме fstab, его обработаем отдельно)
  for f in /etc/sysctl.conf /etc/default/ufw /etc/ufw/before.rules /etc/ufw/user.rules /etc/ufw/user6.rules /etc/security/limits.conf /etc/modules-load.d/modules.conf; do
    local name=$(echo "$f" | sed 's/^\///; s/\//_/g')
    if [ -f "${backup_dir}/${name}" ]; then
      cp "${backup_dir}/${name}" "$f"
      echo "  [✓] восстановлен $f"
    fi
  done

  # --- Восстанавливаем fstab и swap ---
  if [ -f "${backup_dir}/swap_info.txt" ]; then
    source <(grep -E '^(exists|size_mb)=' "${backup_dir}/swap_info.txt")
    # Удаляем текущий swap, если он есть
    if [ -f /swapfile ]; then
      swapoff /swapfile || true
      rm -f /swapfile
      # Удаляем запись из fstab, если она была добавлена нами (строка с /swapfile)
      sed -i '/\/swapfile/d' /etc/fstab
    fi
    # Восстанавливаем оригинальный fstab, если он был сохранён
    if [ -f "${backup_dir}/etc_fstab" ]; then
      cp "${backup_dir}/etc_fstab" /etc/fstab
    fi
    # Если swap существовал до настройки, создаём его с исходным размером
    if [ "$exists" = "yes" ] && [ "$size_mb" -gt 0 ]; then
      echo "[*] Восстанавливаем swap размером ${size_mb} МБ..."
      dd if=/dev/zero of=/swapfile bs=1M count=$size_mb
      chmod 600 /swapfile
      mkswap /swapfile
      swapon /swapfile
      # Добавляем запись в fstab, если её ещё нет (восстановленный fstab мог её содержать, но проверим)
      if ! grep -q '/swapfile' /etc/fstab; then
        echo "/swapfile none swap sw 0 0" >> /etc/fstab
      fi
      echo "  [✓] swap восстановлен."
    else
      echo "  [✓] swap удалён (его не было до настройки)."
    fi
  fi

  # Восстанавливаем состояние ufw
  if [ -f "${backup_dir}/ufw_status.txt" ]; then
    local status=$(cat "${backup_dir}/ufw_status.txt")
    if [ "$status" = "inactive" ]; then
      ufw disable
      echo "  [✓] ufw выключен (как было до настройки)"
    else
      ufw enable
      echo "  [✓] ufw включён (как было до настройки)"
    fi
  fi

  # Перезагружаем sysctl
  sysctl -p /etc/sysctl.conf

  # Удаляем маркер активного профиля, если он совпадает
  if [ -f "$ACTIVE_FILE" ] && [ "$(cat "$ACTIVE_FILE")" = "$profile" ]; then
    rm -f "$ACTIVE_FILE"
  fi

  # Удаляем папку бэкапов
  rm -rf "$backup_dir"
  echo "[✓] Откат '$profile' завершён."
}

# --- Парсинг аргументов ---
TCP_PORTS=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --tcp-ports)
      TCP_PORTS="$2"
      shift 2
      ;;
    *)
      echo "[×] Неизвестный параметр: $1"
      echo "Использование: $0 [--tcp-ports 'порт1,порт2,...']"
      exit 1
      ;;
  esac
done

# --- Переключение на профиль tcp ---
switch_profile "tcp"

trap 'echo ""; echo "[!] Прервано. Выполняем откат..."; rollback_profile "tcp"; exit 1' INT TERM

# --- Установка пакетов ---
apt-get update
for pkg in ufw curl wget; do
  if ! command -v $pkg &> /dev/null; then
    echo "[*] Устанавливаем $pkg..."
    apt-get install -y $pkg
  fi
done

# --- SWAP (2 ГБ) ---
TARGET_SWAP_GB=2
TARGET_SWAP_MB=$((TARGET_SWAP_GB * 1024))
SWAP_FILE="/swapfile"
CREATE_SWAP=true
if [ -f "$SWAP_FILE" ]; then
  CURRENT_SWAP_BYTES=$(stat -c%s "$SWAP_FILE" || echo 0)
  CURRENT_SWAP_MB=$((CURRENT_SWAP_BYTES / 1024 / 1024))
  DIFF_MB=$((CURRENT_SWAP_MB - TARGET_SWAP_MB))
  ABS_DIFF_MB=${DIFF_MB#-}
  if [ "$ABS_DIFF_MB" -le 50 ]; then
    echo "[✓] SWAP уже правильного размера."
    CREATE_SWAP=false
  else
    swapoff "$SWAP_FILE" || true
    rm -f "$SWAP_FILE"
  fi
fi
if [ "$CREATE_SWAP" = true ]; then
  dd if=/dev/zero of="$SWAP_FILE" bs=1M count=$TARGET_SWAP_MB status=progress
  chmod 600 "$SWAP_FILE"
  mkswap "$SWAP_FILE"
  swapon "$SWAP_FILE"
  if ! grep -q "$SWAP_FILE" /etc/fstab; then
    echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
  fi
  echo "[✓] SWAP настроен."
fi

# --- sysctl ---
SYSCTL_MARKER_START="# === server-preparation-tcp-start ==="
SYSCTL_MARKER_END="# === server-preparation-tcp-end ==="

echo "[*] Очищаем старые настройки sysctl..."
# Удаляем старый блок, если есть
sed -i "/$SYSCTL_MARKER_START/,/$SYSCTL_MARKER_END/d" /etc/sysctl.conf

# Добавляем новый блок с маркерами
cat << EOF >> /etc/sysctl.conf
$SYSCTL_MARKER_START
# Отключение IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1

# BBR + планировщик
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Стандартные буферы для TCP (1GB RAM)
net.core.rmem_max = 8388608
net.core.wmem_max = 8388608
net.ipv4.tcp_rmem = 4096 87380 8388608
net.ipv4.tcp_wmem = 4096 65536 8388608

net.core.netdev_max_backlog = 5000
net.core.somaxconn = 1024

net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5

net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048

vm.swappiness = 10

# TCP Fast Open
net.ipv4.tcp_fastopen = 3
$SYSCTL_MARKER_END
EOF

# --- Модуль BBR ---
modprobe tcp_bbr || true
if ! grep -q "^tcp_bbr" /etc/modules-load.d/modules.conf; then
  echo "tcp_bbr" >> /etc/modules-load.d/modules.conf
fi

sysctl -p /etc/sysctl.conf

# --- UFW IPv6 ---
[ -f /etc/default/ufw ] && sed -i 's/IPV6=yes/IPV6=no/g' /etc/default/ufw

# --- ulimit ---
if ! grep -q "nofile 65535" /etc/security/limits.conf; then
  echo -e "* soft nofile 65535\n* hard nofile 65535\nroot soft nofile 65535\nroot hard nofile 65535" >> /etc/security/limits.conf
fi

# --- Настройка UFW правил ---
if command -v ufw >/dev/null 2>&1; then
  ufw default deny incoming
  ufw default allow outgoing
  # Определяем текущий SSH порт (если изменён)
  SSH_PORT=$(grep -E "^Port " /etc/ssh/sshd_config | awk '{print $2}' | head -1)
  [ -z "$SSH_PORT" ] && SSH_PORT=22

  # Разрешаем SSH по номеру порта (на случай, если порт нестандартный)
  ufw allow "$SSH_PORT"/tcp
  # Также разрешаем по имени сервиса (для надёжности)
  ufw allow ssh
  ufw allow 2222/tcp
  ufw allow 443/tcp

  if [ -n "$TCP_PORTS" ]; then
    IFS=',' read -ra PORTS <<< "$TCP_PORTS"
    for port in "${PORTS[@]}"; do
      if [[ "$port" =~ ^[0-9]+$ ]]; then
        ufw allow "$port"/tcp
        echo "[*] Открыт TCP-порт $port"
      else
        echo "[!] Некорректный порт: $port (пропускаем)"
      fi
    done
  fi

  # Отключение ICMP
  echo "[*] Настраиваем отключение ICMP (ping) через UFW..."
  if [ -f /etc/ufw/before.rules ]; then
      # Удаляем только наше правило (с комментарием)
      sed -i '/# no-icmp-request/d' /etc/ufw/before.rules
      # Добавляем правило с комментарием
      if grep -q "^COMMIT" /etc/ufw/before.rules; then
          sed -i '/^COMMIT/i # no-icmp-request\n-A ufw-before-input -p icmp --icmp-type echo-request -j DROP' /etc/ufw/before.rules
          echo "[✓] Правило для ICMP добавлено."
      else
          echo "[!] COMMIT не найден в /etc/ufw/before.rules. ICMP не отключён."
      fi
  else
      echo "[!] /etc/ufw/before.rules не найден. ICMP не отключён."
  fi

  yes | ufw enable
  ufw reload
else
  echo "[×] UFW не установлен. Пропускаем настройку файрвола."
fi

# --- Итог ---
echo -e "\n=== Настройка завершена ===\n"
set +e
echo "--- Проверка BBR ---"
BBR_SYSCTL=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
[ "$BBR_SYSCTL" = "bbr" ] && echo "[✓] BBR активен." || echo "[×] BBR не активирован."

echo "--- Проверка ICMP ---"
if grep -q "icmp --icmp-type echo-request -j DROP" /etc/ufw/before.rules; then
  echo "[✓] ICMP отключён в UFW."
else
  echo "[×] ICMP не отключён в UFW."
fi

echo "--- Проверка IPv6 ---"
[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6)" = "1" ] && echo "[✓] IPv6 отключён." || echo "[×] IPv6 не отключён (требуется перезагрузка)."

echo -e "\n--- SWAP ---"
free -h | grep -E "Mem|Swap"

if command -v ufw >/dev/null 2>&1; then
  echo -e "\n--- UFW ---"
  ufw status verbose
fi

echo -e "\n--- Слушаемые порты ---"
ss -tuln

# --- Снимаем trap после успешного выполнения ---
trap - INT TERM

echo -e "\n[✓] Настройки оптимизированы для TCP-ориентированного трафика."
echo "[*] Бэкапы сохранены в $BACKUP_DIR"
echo "[*] Для отката используйте: curl -fsSL https://raw.githubusercontent.com/OrlovVl/server-preparation/refs/heads/main/rollback/rollback-tcp.sh | bash"
exit 0
