#!/bin/bash
# MTproxy-reanimation — быстрая установка
# Использование: curl -fsSL https://raw.githubusercontent.com/Liafanx/MTproxy-reanimation/main/install.sh | sudo bash
set -e
SCRIPT_URL="https://raw.githubusercontent.com/Liafanx/MTproxy-reanimation/dev/mtpr.sh"
if [ "$(id -u)" -ne 0 ]; then echo "Запустите от root: curl -fsSL ... | sudo bash" >&2; exit 1; fi
mkdir -p /opt/mtproxy-reanimation
curl -fsSL "$SCRIPT_URL" -o /opt/mtproxy-reanimation/mtpr.sh
chmod +x /opt/mtproxy-reanimation/mtpr.sh
ln -sf /opt/mtproxy-reanimation/mtpr.sh /usr/local/bin/mtpr
echo "MTproxy-reanimation установлен."
# Запускаем скрипт с stdin от терминала
exec /opt/mtproxy-reanimation/mtpr.sh </dev/tty
