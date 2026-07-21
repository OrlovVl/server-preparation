#!/bin/bash
set -o pipefail
set -e

if [ "$EUID" -ne 0 ]; then
    echo "[×] Запускайте от root."
    exit 1
fi

echo "[*] Откат очистки системы (cron)..."

CLEANUP_SCRIPT="/usr/local/bin/cleanup-system.sh"

cron_output=$(crontab -l 2>/dev/null || true)

if echo "$cron_output" | grep -q "$CLEANUP_SCRIPT"; then
    echo "$cron_output" | grep -v "$CLEANUP_SCRIPT" | crontab -
    echo "[✓] Cron-задание удалено."
else
    echo "[✓] Cron-задание не найдено."
fi

if [[ -f "$CLEANUP_SCRIPT" ]]; then
    rm -f "$CLEANUP_SCRIPT"
    echo "[✓] Скрипт очистки удалён."
fi

echo "[✓] Откат очистки системы завершён."
exit 0