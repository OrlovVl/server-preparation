#!/bin/bash
set -e

echo "=== Настройка сервера (UDP/TCP-оптимизация) ==="

if [ "$EUID" -ne 0 ]; then
  echo "[×] Запускайте от root."
  exit 1
fi

# --- Парсинг аргументов (доп. TCP и UDP порты) ---
TCP_PORTS=""
UDP_PORTS=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --tcp-ports)
      TCP_PORTS="$2"
      shift 2
      ;;
    --udp-ports)
      UDP_PORTS="$2"
      shift 2
      ;;
    *)
      echo "[×] Неизвестный параметр: $1"
      echo "Использование: $0 [--tcp-ports 'порт1,порт2,...'] [--udp-ports 'порт1,порт2,...']"
      exit 1
      ;;
  esac
done

# --- Установка пакетов ---
apt-get update -qq
for pkg in ufw curl wget; do
  if ! command -v $pkg &> /dev/null; then
    apt-get install -y -qq $pkg
  fi
done

# --- SWAP (2 ГБ) ---
TARGET_SWAP_GB=2
TARGET_SWAP_MB=$((TARGET_SWAP_GB * 1024))
SWAP_FILE="/swapfile"
CREATE_SWAP=true
if [ -f "$SWAP_FILE" ]; then
  CURRENT_SWAP_BYTES=$(stat -c%s "$SWAP_FILE" 2>/dev/null || echo 0)
  CURRENT_SWAP_MB=$((CURRENT_SWAP_BYTES / 1024 / 1024))
  DIFF_MB=$((CURRENT_SWAP_MB - TARGET_SWAP_MB))
  ABS_DIFF_MB=${DIFF_MB#-}
  if [ "$ABS_DIFF_MB" -le 50 ]; then
    echo "[✓] SWAP уже правильного размера."
    CREATE_SWAP=false
  else
    swapoff "$SWAP_FILE" 2>/dev/null || true
    rm -f "$SWAP_FILE"
  fi
fi
if [ "$CREATE_SWAP" = true ]; then
  fallocate -l ${TARGET_SWAP_GB}G "$SWAP_FILE" || dd if=/dev/zero of="$SWAP_FILE" bs=1M count=$TARGET_SWAP_MB
  chmod 600 "$SWAP_FILE"
  mkswap "$SWAP_FILE"
  swapon "$SWAP_FILE"
  if ! grep -q "$SWAP_FILE" /etc/fstab; then
    echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
  fi
  echo "[✓] SWAP настроен."
fi

# --- Полная очистка старых настроек sysctl ---
echo "[*] Очищаем старые настройки sysctl..."
cp /etc/sysctl.conf /etc/sysctl.conf.bak.$(date +%s)
grep -vE '^(net\.ipv6\.conf\.(all|default|lo)\.disable_ipv6|net\.core\.default_qdisc|net\.ipv4\.tcp_congestion_control|net\.core\.rmem_max|net\.core\.wmem_max|net\.core\.rmem_default|net\.core\.wmem_default|net\.ipv4\.udp_rmem_min|net\.ipv4\.udp_wmem_min|net\.core\.netdev_max_backlog|net\.core\.somaxconn|net\.ipv4\.tcp_tw_reuse|net\.ipv4\.tcp_fin_timeout|net\.ipv4\.tcp_max_tw_buckets|net\.ipv4\.tcp_keepalive_time|net\.ipv4\.tcp_keepalive_intvl|net\.ipv4\.tcp_keepalive_probes|net\.ipv4\.tcp_syncookies|net\.ipv4\.tcp_max_syn_backlog|vm\.swappiness)' /etc/sysctl.conf > /etc/sysctl.conf.new
mv /etc/sysctl.conf.new /etc/sysctl.conf

# --- Добавляем новые настройки ---
echo "[*] Добавляем настройки sysctl для работы с UDP и большими нагрузками..."
cat << 'EOF' >> /etc/sysctl.conf

# Отключение IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1

# BBR
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Увеличенные буферы для UDP и больших объёмов данных
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# Увеличенные очереди
net.core.netdev_max_backlog = 10000
net.core.somaxconn = 4096

# Ускоренное освобождение TIME_WAIT
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 2000000

# keepalive
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5

# защита
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048

vm.swappiness = 10
EOF

# --- Загрузка модуля BBR ---
modprobe tcp_bbr 2>/dev/null || true
echo "tcp_bbr" >> /etc/modules-load.d/modules.conf 2>/dev/null || true

# --- Применение всех настроек sysctl ---
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
  # Базовые порты (22, 2222, 443/tcp, 443/udp)
  ufw allow 22/tcp
  ufw allow 2222/tcp
  ufw allow 443/tcp
  ufw allow 443/udp

  # Дополнительные TCP-порты
  if [ -n "$TCP_PORTS" ]; then
    IFS=',' read -ra PORTS <<< "$TCP_PORTS"
    for port in "${PORTS[@]}"; do
      if [[ "$port" =~ ^[0-9]+$ ]]; then
        ufw allow "$port"/tcp
        echo "[*] Открыт TCP-порт $port"
      else
        echo "[!] Некорректный TCP-порт: $port (пропускаем)"
      fi
    done
  fi

  # Дополнительные UDP-порты
  if [ -n "$UDP_PORTS" ]; then
    IFS=',' read -ra PORTS <<< "$UDP_PORTS"
    for port in "${PORTS[@]}"; do
      if [[ "$port" =~ ^[0-9]+$ ]]; then
        ufw allow "$port"/udp
        echo "[*] Открыт UDP-порт $port"
      else
        echo "[!] Некорректный UDP-порт: $port (пропускаем)"
      fi
    done
  fi

  # --- Отключение ICMP через UFW ---
  echo "[*] Настраиваем отключение ICMP (ping) через UFW..."
  if [ -f /etc/ufw/before.rules ]; then
    cp /etc/ufw/before.rules /etc/ufw/before.rules.bak.$(date +%s)
    sed -i '/icmp --icmp-type echo-request -j/d' /etc/ufw/before.rules
    sed -i '/^COMMIT/i -A ufw-before-input -p icmp --icmp-type echo-request -j DROP' /etc/ufw/before.rules
    echo "[✓] Правило для ICMP обновлено (дубликаты удалены)."
  else
    echo "[!] Файл /etc/ufw/before.rules не найден. ICMP не отключён."
  fi

  yes | ufw enable
  ufw reload
else
  echo "[×] UFW не установлен. Пропускаем настройку файрвола."
fi

# --- Итоговая проверка ---
echo -e "\n=== Настройка завершена ===\n"
set +e

echo "--- Проверка BBR ---"
BBR_SYSCTL=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
[ "$BBR_SYSCTL" = "bbr" ] && echo "[✓] BBR активен." || echo "[×] BBR не активирован."

echo "--- Проверка ICMP ---"
if grep -q "icmp --icmp-type echo-request -j DROP" /etc/ufw/before.rules 2>/dev/null; then
  echo "[✓] ICMP отключён в UFW."
else
  echo "[×] ICMP не отключён в UFW (проверьте /etc/ufw/before.rules)."
fi

echo "--- Проверка IPv6 ---"
[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)" = "1" ] && echo "[✓] IPv6 отключён." || echo "[×] IPv6 не отключён (требуется перезагрузка)."

echo -e "\n--- SWAP ---"
free -h | grep -E "Mem|Swap"

if command -v ufw >/dev/null 2>&1; then
  echo -e "\n--- UFW ---"
  ufw status verbose
fi

echo -e "\n--- Слушаемые порты ---"
ss -tuln

echo -e "\n[✓] Настройки оптимизированы для смешанного трафика (TCP + UDP), включая QUIC и другие протоколы с большими пакетами."
