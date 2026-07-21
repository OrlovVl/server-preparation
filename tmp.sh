#!/bin/bash
set -e

echo "=== Откат изменений, внесённых setup-old.sh ==="

if [ "$EUID" -ne 0 ]; then
  echo "[×] Запускайте от root."
  exit 1
fi

# --- 1. Создаём бэкап текущих файлов перед откатом (на всякий случай) ---
BACKUP_DIR="/opt/remnanode/backups/old_setup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
echo "[*] Сохраняем текущие файлы в $BACKUP_DIR"
cp /etc/sysctl.conf "$BACKUP_DIR/"
cp /etc/default/ufw "$BACKUP_DIR/" 2>/dev/null || true
cp /etc/security/limits.conf "$BACKUP_DIR/" 2>/dev/null || true
cp /etc/fstab "$BACKUP_DIR/" 2>/dev/null || true

# --- 2. Восстанавливаем sysctl.conf ---
echo "[*] Удаляем блок, добавленный старым скриптом..."
# Старый скрипт добавлял блок, начиная с "# Отключение IPv6" и до конца файла.
# Удаляем все строки от "# Отключение IPv6" до конца файла.
# Но если там были другие важные настройки, они тоже удалятся.
# Чтобы минимизировать риск, проверяем наличие маркера.
if grep -q "# Отключение IPv6" /etc/sysctl.conf; then
    # Удаляем строки от маркера до конца файла
    sed -i '/# Отключение IPv6/,$d' /etc/sysctl.conf
    echo "  [✓] Блок удалён."
else
    echo "  [!] Маркер не найден, возможно, скрипт уже откатывался."
fi

# --- 3. Возвращаем IPv6 в UFW (если было изменено) ---
if [ -f /etc/default/ufw ]; then
    echo "[*] Восстанавливаем настройку IPv6 в UFW..."
    sed -i 's/IPV6=no/IPV6=yes/g' /etc/default/ufw
    echo "  [✓] IPv6 включён в UFW."
else
    echo "  [!] /etc/default/ufw не найден."
fi

# --- 4. Удаляем добавленные лимиты из limits.conf (если они были) ---
if [ -f /etc/security/limits.conf ]; then
    echo "[*] Удаляем строки, добавленные старым скриптом..."
    # Старый скрипт добавлял:
    # * soft nofile 65535
    # * hard nofile 65535
    # root soft nofile 65535
    # root hard nofile 65535
    # Удаляем эти строки, если они есть
    sed -i '/\* soft nofile 65535/d' /etc/security/limits.conf
    sed -i '/\* hard nofile 65535/d' /etc/security/limits.conf
    sed -i '/root soft nofile 65535/d' /etc/security/limits.conf
    sed -i '/root hard nofile 65535/d' /etc/security/limits.conf
    echo "  [✓] Строки удалены."
fi

# --- 5. Отключаем и удаляем SWAP-файл, созданный скриптом (если он есть) ---
SWAP_FILE="/swapfile"
if [ -f "$SWAP_FILE" ]; then
    echo "[*] Обнаружен SWAP-файл. Отключаем и удаляем..."
    swapoff "$SWAP_FILE" 2>/dev/null || true
    rm -f "$SWAP_FILE"
    # Удаляем запись из fstab, если она есть
    sed -i '/\/swapfile/d' /etc/fstab
    echo "  [✓] SWAP-файл удалён, запись из fstab убрана."
else
    echo "  [!] SWAP-файл не найден."
fi

# --- 6. Сбрасываем UFW и отключаем его ---
if command -v ufw >/dev/null 2>&1; then
    echo "[*] Сбрасываем UFW к дефолтным правилам и отключаем..."
    ufw --force reset
    ufw disable
    echo "  [✓] UFW сброшен и отключён. Новые скрипты настроят его заново."
fi

# --- 7. Перезагружаем sysctl, чтобы применить изменения ---
sysctl -p /etc/sysctl.conf

echo ""
echo "[✓] Откат изменений, внесённых setup-old.sh, завершён."
echo "================================================================================"
echo "[*] Бэкап файлов сохранён в $BACKUP_DIR"
echo "[*] Теперь вы можете безопасно запускать новые скрипты (setup-tcp.sh и т.д.)"
echo "[*] Рекомендуется перезагрузить сервер для полного применения изменений."
echo "================================================================================"

echo "=== Проверка после отката ==="
echo "1. /etc/sysctl.conf (не должно быть маркеров старого скрипта):"
grep -E "# Отключение IPv6|# Тюнинг сети" /etc/sysctl.conf || echo "  [✓] Ок"
echo "2. /etc/default/ufw (IPV6):"
grep IPV6 /etc/default/ufw
echo "3. /etc/security/limits.conf (nofile):"
grep nofile /etc/security/limits.conf || echo "  [✓] Ок"
echo "4. /etc/fstab (swapfile):"
grep swapfile /etc/fstab || echo "  [✓] Ок"
echo "5. SWAP-файл:"
ls -l /swapfile 2>&1 | grep "No such file" && echo "  [✓] Ок" || echo "  [!] Файл существует"
echo "6. UFW статус:"
ufw status | grep inactive && echo "  [✓] Ок" || echo "  [!] UFW активен"
echo "7. Текущий алгоритм TCP:"
sysctl net.ipv4.tcp_congestion_control
echo "8. TCP Fast Open:"
sysctl net.ipv4.tcp_fastopen