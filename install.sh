#!/bin/bash
# MTproxy-reanimation Quick Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/Liafanx/MTproxy-reanimation/main/install.sh | bash
set -e
SCRIPT_URL="https://raw.githubusercontent.com/Liafanx/MTproxy-reanimation/main/mtpr.sh"
if [ "$(id -u)" -ne 0 ]; then echo "Run as root: curl -fsSL ... | sudo bash" >&2; exit 1; fi
mkdir -p /opt/mtproxy-reanimation
curl -fsSL "$SCRIPT_URL" -o /opt/mtproxy-reanimation/mtpr.sh
chmod +x /opt/mtproxy-reanimation/mtpr.sh
ln -sf /opt/mtproxy-reanimation/mtpr.sh /usr/local/bin/mtpr
echo "MTproxy-reanimation installed. Run: mtpr"
mtpr
