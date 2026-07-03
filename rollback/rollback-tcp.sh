#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "[×] Запускайте от root."
  exit 1
fi

BACKUP_BASE="/opt/remnanode/backups"
BACKUP_DIR="${BACKUP_BASE}/tcp"
ACTIVE_FILE="${BACKUP_BASE}/active"

if [ ! -d "$BACKUP_DIR" ]; then
  echo "[!] Бэкапы для TCP не найдены. Откат не требуется."
  exit 0
fi

echo "[*] Выполняем откат TCP-оптимизации..."

# Восстанавливаем файлы (кроме fstab)
for f in /etc/sysctl.conf /etc/default/ufw /etc/ufw/before.rules /etc/ufw/user.rules /etc/ufw/user6.rules /etc/security/limits.conf /etc/modules-load.d/modules.conf; do
  name=$(echo "$f" | sed 's/^\///; s/\//_/g')
  if [ -f "${BACKUP_DIR}/${name}" ]; then
    cp "${BACKUP_DIR}/${name}" "$f"
    echo "  [✓] восстановлен $f"
  fi
done

# --- Восстанавливаем fstab и swap ---
if [ -f "${BACKUP_DIR}/swap_info.txt" ]; then
  source <(grep -E '^(exists|size_mb)=' "${BACKUP_DIR}/swap_info.txt")
  # Удаляем текущий swap, если он есть
  if [ -f /swapfile ]; then
    swapoff /swapfile 2>/dev/null || true
    rm -f /swapfile
    sed -i '/\/swapfile/d' /etc/fstab
  fi
  # Восстанавливаем оригинальный fstab
  if [ -f "${BACKUP_DIR}/etc_fstab" ]; then
    cp "${BACKUP_DIR}/etc_fstab" /etc/fstab
  fi
  # Если swap существовал до настройки, создаём его с исходным размером
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

# Восстанавливаем состояние ufw
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

if [ -f "$ACTIVE_FILE" ] && [ "$(cat "$ACTIVE_FILE")" = "tcp" ]; then
  rm -f "$ACTIVE_FILE"
  echo "[✓] Маркер активного профиля удалён."
fi

rm -rf "$BACKUP_DIR"
echo "[✓] Бэкапы удалены."

echo "[✓] Откат TCP-оптимизации завершён."
echo "[*] Примечание: если вы открывали порты вручную после настройки, они будут удалены."
exit 0
