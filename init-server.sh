#!/bin/bash
set -e

echo "=== Базовая подготовка сервера ==="

if [ "$EUID" -ne 0 ]; then
  echo "[×] Запускайте от root."
  exit 1
fi

systemctl stop docker.socket || true
apt-get purge -y docker.io
apt-get autoremove -y
systemctl daemon-reload
apt-get update
apt-get full-upgrade -y
apt-get autoremove -y
apt-get clean
curl -fsSL https://get.docker.com | sh

echo "[✓] Готово. Docker установлен."
