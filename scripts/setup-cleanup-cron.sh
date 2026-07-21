#!/bin/bash
set -o pipefail
set -e

if [ "$EUID" -ne 0 ]; then
    echo "[×] Запускайте от root."
    exit 1
fi

echo "[*] Устанавливаем скрипт очистки системы и cron-задание..."

CLEANUP_SCRIPT="/usr/local/bin/cleanup-system.sh"
cat > "$CLEANUP_SCRIPT" <<'EOF'
#!/bin/bash
set -e

# --- 1. Очистка Docker (без удаления томов) ---
echo "[*] Очистка Docker (удаление неиспользуемых контейнеров, образов и кэша сборки)..."
docker system prune -af
docker builder prune -af 2>/dev/null || true

# --- 2. Очистка APT ---
echo "[*] Очистка APT..."
apt-get autoremove -y
apt-get clean

# --- 3. Очистка системных логов journald (оставляем 7 дней) ---
echo "[*] Очистка systemd journal..."
journalctl --vacuum-time=7d

# --- 4. Удаление старых временных файлов --- 
echo "[*] Очистка /tmp и /var/tmp (старше 7 дней)..."
find /tmp -type f -atime +7 -delete 2>/dev/null || true
find /var/tmp -type f -atime +7 -delete 2>/dev/null || true

# --- 5. Очистка старых ротированных логов (старше 14 дней) ---
echo "[*] Удаление старых логов в /var/log..."
find /var/log -type f \( -name "*.gz" -o -name "*.[0-9]" -o -name "*-20*" \) -mtime +14 -delete 2>/dev/null || true

# --- 6. Удаление старых core-дампов ---
echo "[*] Удаление старых core-дампов..."
find / -name "core.*" -type f -mtime +7 -delete 2>/dev/null || true

# --- 7. Очистка логов самого скрипта очистки (старше 30 дней) ---
echo "[*] Очистка старых логов cleanup-system.log..."
find /var/log -name "cleanup-system.log*" -type f -mtime +30 -delete 2>/dev/null || true

echo "[✓] Очистка системы завершена."
EOF

chmod +x "$CLEANUP_SCRIPT"

# --- Добавляем cron-задание (еженедельно в воскресенье 3:00) ---
CRON_JOB="0 3 * * 0 $CLEANUP_SCRIPT >> /var/log/cleanup-system.log 2>&1"
if crontab -l 2>/dev/null | grep -q "$CLEANUP_SCRIPT"; then
    echo "[✓] Cron-задание уже существует."
else
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
    echo "[✓] Cron-задание добавлено: $CRON_JOB"
fi

# --- Вывод логов remnanode ---
echo "[*] Просмотр логов контейнера remnanode (15 секунд)..."
timeout 15 $DOCKER_COMPOSE -f /opt/remnanode/docker-compose.yml logs -f || true
echo "[*] Продолжаем выполнение..."

# --- Принудитльный тестовый запуск ---
echo ""
echo "[*] Выполняем тестовый запуск скрипта очистки для проверки..."
echo "================================================================================"
if "$CLEANUP_SCRIPT"; then
    echo "================================================================================"
    echo "[✓] Тестовый запуск завершён успешно."
else
    echo "================================================================================"
    echo "[×] Тестовый запуск завершился с ошибкой. Проверьте логи."
fi

echo ""
echo "[✓] Очистка системы настроена (cron: $CRON_JOB)"
echo "[*] Скрипт очистки: $CLEANUP_SCRIPT"
echo "[*] Лог очистки: /var/log/cleanup-system.log (автоматически ротируется при очистке)"
sleep 2
exit 0