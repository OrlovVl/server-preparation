#!/bin/bash
set -e

echo "=== Старт настройки сервера для VLESS Reality ==="

if [ "$EUID" -ne 0 ]; then
  echo "[×] Запускайте от root."
  exit 1
fi

# --- Установка нужных пакетов (без Docker) ---
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

# --- sysctl ---
echo "[*] Настраиваем sysctl (Reality + BBR + отключение IPv6/ICMP)..."

sed -i '/# Отключение IPv6/,$d' /etc/sysctl.conf
sed -i '/# Тюнинг сети/,$d' /etc/sysctl.conf
sed -i '/# Отключение ICMP/,$d' /etc/sysctl.conf

cat << 'EOF' >> /etc/sysctl.conf

# Отключение IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1

# Отключение ICMP (ping)
net.ipv4.icmp_echo_ignore_all = 1

# Тюнинг сети для 1GB RAM (оптимально для Reality)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

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

# --- BBR ---
modprobe tcp_bbr 2>/dev/null || true
echo "tcp_bbr" >> /etc/modules-load.d/modules.conf 2>/dev/null || true
sysctl -p /etc/sysctl.conf

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
  ufw allow 22/tcp
  ufw allow 2222/tcp
  ufw allow 443
  yes | ufw enable
else
  echo "[×] UFW не установлен. Пропускаем."
fi

# --- Итоговая проверка ---
echo -e "\n=== Настройка завершена ===\n"
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
