#!/bin/bash
set -e

echo "=== Настройка сервера (TCP-оптимизация) ==="

if [ "$EUID" -ne 0 ]; then
  echo "[×] Запускайте от root."
  exit 1
fi

# --- Парсинг аргументов (доп. TCP-порты) ---
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

# --- Установка нужных пакетов ---
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
grep -vE '^(net\.ipv6\.conf\.(all|default|lo)\.disable_ipv6|net\.ipv4\.icmp_echo_ignore_all|net\.core\.default_qdisc|net\.ipv4\.tcp_congestion_control|net\.core\.rmem_max|net\.core\.wmem_max|net\.ipv4\.tcp_rmem|net\.ipv4\.tcp_wmem|net\.core\.netdev_max_backlog|net\.core\.somaxconn|net\.ipv4\.tcp_tw_reuse|net\.ipv4\.tcp_fin_timeout|net\.ipv4\.tcp_keepalive_time|net\.ipv4\.tcp_keepalive_intvl|net\.ipv4\.tcp_keepalive_probes|net\.ipv4\.tcp_syncookies|net\.ipv4\.tcp_max_syn_backlog|vm\.swappiness)' /etc/sysctl.conf > /etc/sysctl.conf.new
mv /etc/sysctl.conf.new /etc/sysctl.conf

# --- Добавляем новые настройки ---
echo "[*] Добавляем настройки sysctl для TCP-оптимизации..."
cat << 'EOF' >> /etc/sysctl.conf

# Отключение IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1

# Отключение ICMP (ping)
net.ipv4.icmp_echo_ignore_all = 1

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
EOF

# --- BBR и применение ---
modprobe tcp_bbr 2>/dev/null || true
echo "tcp_bbr" >> /etc/modules-load.d/modules.conf 2>/dev/null || true
sysctl -p /etc/sysctl.conf
sysctl -w net.ipv4.icmp_echo_ignore_all=1 >/dev/null

# --- UFW IPv6 ---
[ -f /etc/default/ufw ] && sed -i 's/IPV6=yes/IPV6=no/g' /etc/default/ufw

# --- ulimit ---
if ! grep -q "nofile 65535" /etc/security/limits.conf; then
  echo -e "* soft nofile 65535\n* hard nofile 65535\nroot soft nofile 65535\nroot hard nofile 65535" >> /etc/security/limits.conf
fi

# --- UFW правила ---
if command -v ufw >/dev/null 2>&1; then
  ufw default deny incoming
  ufw default allow outgoing
  # Базовые порты
  ufw allow 22/tcp
  ufw allow 2222/tcp
  ufw allow 443/tcp

  # Дополнительные TCP-порты
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

  yes | ufw enable
else
  echo "[×] UFW не установлен. Пропускаем."
fi

# --- Итоговая проверка ---
echo -e "\n=== Настройка завершена! ===\n"
set +e

echo "--- Проверка BBR ---"
BBR_SYSCTL=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
[ "$BBR_SYSCTL" = "bbr" ] && echo "[✓] BBR активен." || echo "[×] BBR не активирован."

echo "--- Проверка ICMP ---"
[ "$(sysctl -n net.ipv4.icmp_echo_ignore_all 2>/dev/null)" = "1" ] && echo "[✓] ICMP отключён." || echo "[×] ICMP не отключён."

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

echo -e "\n[✓] Настройки оптимизированы для TCP-ориентированного трафика (например, TLS-туннели, WebSocket, gRPC)."
