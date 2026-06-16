#!/bin/bash

# Выход при ошибке в любой команде (до блока проверок)
set -e

echo "=== Старт настройки сервера ==="

if [ "$EUID" -ne 0 ]; then
  echo "[×] Этот скрипт нужно запускать от имени root (или через sudo)."
  exit 1
fi

echo "[*] Отключаем IPv6..."
if ! grep -q "net.ipv6.conf.all.disable_ipv6" /etc/sysctl.conf; then
  echo -e "\n# Отключение IPv6\nnet.ipv6.conf.all.disable_ipv6 = 1\nnet.ipv6.conf.default.disable_ipv6 = 1\nnet.ipv6.conf.lo.disable_ipv6 = 1" >> /etc/sysctl.conf
fi
sysctl -p /etc/sysctl.conf

if [ -f /etc/default/ufw ]; then
  echo "[*] Отключаем IPv6 в конфигурации UFW..."
  sed -i 's/IPV6=yes/IPV6=no/g' /etc/default/ufw
else
  echo "[!] Файл /etc/default/ufw не найден. Возможно, UFW не установлен."
fi

echo "[*] Включаем BBR..."
if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
  echo -e "\n# Включение BBR\nnet.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
fi
sysctl -p /etc/sysctl.conf

echo "[*] Настраиваем правила UFW 22/tcp, 2222/tcp и 443/tcp..."
if command -v ufw >/dev/null 2>&1; then
  ufw allow 22/tcp
  ufw allow 2222/tcp
  ufw allow 443/tcp
  
  ufw default deny incoming
  ufw default allow outgoing
  
  # Включаем UFW, принудительно отвечая "yes" на возможные вопросы о разрыве SSH
  yes | ufw enable
else
  echo "[×] UFW не установлен в системе. Пропускаем настройку фаервола."
fi

echo -e "\n=== Настройка завершена! Начинаем проверку... ===\n"

# Временно отключаем падение скрипта при ошибках для блока проверок
set +e 

echo "--- Проверка IPv6: ---"
# Локально отключаем set -e для grep, чтобы скрипт не умер
ip a | grep -q "inet6"
if [ $? -eq 0 ]; then
  echo "[!] Внимание: IPv6 всё ещё виден в интерфейсах (возможно, требуется перезагрузка)."
else
  echo "[✓] Успех: IPv6 успешно отключен."
fi

echo -e "\n--- Проверка BBR: ---"
BBR_SYSCTL=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
if [ "$BBR_SYSCTL" = "bbr" ]; then
  echo "[✓] Успех: Модуль BBR активен в sysctl."
else
  echo "[×] Ошибка: BBR не активировался в sysctl."
fi

if command -v ufw >/dev/null 2>&1; then
  echo -e "\n--- Статус UFW: ---"
  ufw status verbose
fi

echo -e "\n--- Список слушаемых портов (ss -tuln): ---"
ss -tuln
