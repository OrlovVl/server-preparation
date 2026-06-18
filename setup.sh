#!/bin/bash

# Выход при ошибке в любой команде (до блока проверок)
set -e

echo "=== Старт настройки сервера ==="

if [ "$EUID" -ne 0 ]; then
  echo "[×] Этот скрипт нужно запускать от имени root (или через sudo)."
  exit 1
fi

TARGET_SWAP_GB=2
TARGET_SWAP_MB=$((TARGET_SWAP_GB * 1024))
SWAP_FILE="/swapfile"

echo "[*] Настраиваем SWAP-файл на ${TARGET_SWAP_GB} ГБ..."

CREATE_SWAP=true

if [ -f "$SWAP_FILE" ]; then
  # Получаем размер файла в мегабайтах
  CURRENT_SWAP_BYTES=$(stat -c%s "$SWAP_FILE" 2>/dev/null || echo 0)
  CURRENT_SWAP_MB=$((CURRENT_SWAP_BYTES / 1024 / 1024))

  # Даем небольшую погрешность в 50 МБ на случай особенностей разметки файловой системы
  DIFF_MB=$((CURRENT_SWAP_MB - TARGET_SWAP_MB))
  ABS_DIFF_MB=${DIFF_MB#-}

  if [ "$ABS_DIFF_MB" -le 50 ]; then
    echo "[✓] SWAP-файл уже существует и имеет правильный размер (~${CURRENT_SWAP_MB} МБ). Пропускаем."
    CREATE_SWAP=false
  else
    echo "[!] Найдено несовпадение размеров: текущий размер ${CURRENT_SWAP_MB} МБ, требуется ${TARGET_SWAP_MB} МБ."
    echo "[*] Пересоздаем SWAP-файл под нужный размер..."
    swapoff "$SWAP_FILE" 2>/dev/null || true
    rm -f "$SWAP_FILE"
  fi
fi

if [ "$CREATE_SWAP" = true ]; then
  echo "[*] Создаем новый файл подкачки на ${TARGET_SWAP_GB} ГБ..."
  # Выделяем место под swap (fallocate быстрее, dd — надежный фолбек)
  fallocate -l ${TARGET_SWAP_GB}G "$SWAP_FILE" || dd if=/dev/zero of="$SWAP_FILE" bs=1M count=$TARGET_SWAP_MB
  
  chmod 600 "$SWAP_FILE"
  mkswap "$SWAP_FILE"
  swapon "$SWAP_FILE"
  
  # Добавляем в fstab только если там еще нет этой записи
  if ! grep -q "$SWAP_FILE" /etc/fstab; then
    echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
  fi
  echo "[✓] SWAP успешно настроен и включен."
fi

echo "[*] Настраиваем агрессивный и экономный sysctl для 1 ГБ RAM, BBR и отключаем IPv6..."
# Чистим старые сетевые тюнинги, если скрипт запускается повторно
sed -i '/# Отключение IPv6/,$d' /etc/sysctl.conf
sed -i '/# Тюнинг сети/,$d' /etc/sysctl.conf

cat << 'EOF' >> /etc/sysctl.conf

# Отключение IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1

# Тюнинг сети для слабых VPS (1GB RAM)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Ограничиваем максимальный аппетит сетевых буферов (безопасно для 1ГБ)
net.core.rmem_max = 8388608
net.core.wmem_max = 8388608
net.ipv4.tcp_rmem = 4096 87380 8388608
net.ipv4.tcp_wmem = 4096 65536 8388608

# Защита от переполнения очередей при наплыве пользователей
net.core.netdev_max_backlog = 5000
net.core.somaxconn = 1024

# Быстрое освобождение RAM от закрытых/мертвых соединений
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5

# Защита от SYN-флуда и сканеров портов
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048

# Настройка использования SWAP (не лезть в своп без крайней необходимости)
vm.swappiness = 10
EOF

sysctl -p /etc/sysctl.conf

if [ -f /etc/default/ufw ]; then
  echo "[*] Отключаем IPv6 в конфигурации UFW..."
  sed -i 's/IPV6=yes/IPV6=no/g' /etc/default/ufw
else
  echo "[!] Файл /etc/default/ufw не найден. Возможно, UFW не установлен."
fi

echo "[*] Настраиваем лимиты открытых файлов (ulimit)..."
if ! grep -q "nofile 65535" /etc/security/limits.conf; then
  echo -e "* soft nofile 65535\n* hard nofile 65535\nroot soft nofile 65535\nroot hard nofile 65535" >> /etc/security/limits.conf
fi

echo "[*] Настраиваем правила UFW для SSH, панель и инбаунды..."
if command -v ufw >/dev/null 2>&1; then
  ufw default deny incoming
  ufw default allow outgoing
  
  ufw allow 22/tcp
  ufw allow 2222/tcp
  ufw allow 443
  
  # Включаем UFW, принудительно отвечая "yes" на возможные вопросы о разрыве SSH
  yes | ufw enable
else
  echo "[×] UFW не установлен в системе. Пропускаем настройку фаервола."
fi

echo -e "\n=== Настройка завершена! Начинаем проверку... ===\n"

# Временно отключаем падение скрипта при ошибках для блока проверок
set +e 

echo "--- Проверка IPv6: ---"
ip a | grep -q "inet6"
if [ $? -eq 0 ]; then
  echo "[!] IPv6 всё ещё виден в интерфейсах (возможно, требуется перезагрузка)."
else
  echo "[✓] IPv6 успешно отключен."
fi

echo -e "\n--- Проверка BBR: ---"
BBR_SYSCTL=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
if [ "$BBR_SYSCTL" = "bbr" ]; then
  echo "[✓] Модуль BBR активен в sysctl."
else
  echo "[×] BBR не активировался в sysctl."
fi

echo -e "\n--- Проверка SWAP: ---"
free -h | grep -E "Mem|Swap"

if command -v ufw >/dev/null 2>&1; then
  echo -e "\n--- Статус UFW: ---"
  ufw status verbose
fi

echo -e "\n--- Список слушаемых портов (ss -tuln): ---"
ss -tuln
