#!/bin/bash
set -o pipefail
set -e

if [ "$EUID" -ne 0 ]; then
  echo "[×] Запускайте от root."
  exit 1
fi

trap 'echo ""; echo "[!] Прервано. Откат может быть неполным."; exit 1' INT TERM

BACKUP_BASE="/opt/remnanode/backups"
BACKUP_DIR="${BACKUP_BASE}/tcp-udp"
ACTIVE_FILE="${BACKUP_BASE}/active"

if [ ! -d "$BACKUP_DIR" ]; then
  echo "[!] Бэкапы для TCP-UDP не найдены. Откат не требуется."
  exit 0
fi

echo "[*] Выполняем откат TCP/UDP-оптимизации..."

for f in /etc/sysctl.conf /etc/default/ufw /etc/ufw/before.rules /etc/ufw/user.rules /etc/ufw/user6.rules /etc/security/limits.conf /etc/modules-load.d/modules.conf; do
  name=$(echo "$f" | sed 's/^\///; s/\//_/g')
  if [ -f "${BACKUP_DIR}/${name}" ]; then
    cp "${BACKUP_DIR}/${name}" "$f"
    echo "  [✓] восстановлен $f"
  fi
done

# Восстанавливаем fstab и swap
if [ -f "${BACKUP_DIR}/swap_info.txt" ]; then
  source <(grep -E '^(exists|size_mb)=' "${BACKUP_DIR}/swap_info.txt")
  if [ -f /swapfile ]; then
    swapoff /swapfile || true
    rm -f /swapfile
    sed -i '/\/swapfile/d' /etc/fstab
  fi
  if [ -f "${BACKUP_DIR}/etc_fstab" ]; then
    cp "${BACKUP_DIR}/etc_fstab" /etc/fstab
  fi
  if [ "$exists" = "yes" ] && [ "$size_mb" -gt 0 ]; then
    echo "[*] Восстанавливаем swap размером ${size_mb} МБ..."
    dd if=/dev/zero of=/swapfile bs=1M count=$size_mb
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    if ! grep -q '/swapfile' /etc/fstab; then
      echo "/swapfile none swap sw 0 0" >> /etc/fstab
    fi
    echo "  [✓] swap восстановлен."
  else
    echo "  [✓] swap удалён (его не было до настройки)."
  fi
fi

if [ -f "${BACKUP_DIR}/ufw_status.txt" ]; then
  status=$(cat "${BACKUP_DIR}/ufw_status.txt")
  if [ "$status" = "inactive" ]; then
    ufw disable
    echo "  [✓] ufw выключен (как было до настройки)"
  else
    ufw enable
    echo "  [✓] ufw включён (как было до настройки)"
  fi
fi

sysctl -p /etc/sysctl.conf

if [ -f "$ACTIVE_FILE" ] && [ "$(cat "$ACTIVE_FILE")" = "tcp-udp" ]; then
  rm -f "$ACTIVE_FILE"
  echo "[✓] Маркер активного профиля удалён."
fi

rm -rf "$BACKUP_DIR"
echo "[✓] Бэкапы удалены."

echo "[✓] Откат TCP/UDP-оптимизации завершён."
echo "[*] Примечание: если вы открывали порты вручную после настройки, они будут удалены."
sleep 3
exit 0
