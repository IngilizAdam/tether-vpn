#!/bin/bash
# Install tether-vpn. Run with: sudo ./install.sh   (or: sudo ./install.sh uninstall)
set -euo pipefail
cd "$(dirname "$0")"
[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }

if [[ ${1:-} == uninstall ]]; then
    systemctl stop tether-vpn.service 2>/dev/null || true
    rm -f /usr/local/sbin/tether-vpn /etc/systemd/system/tether-vpn.service \
          /etc/NetworkManager/dispatcher.d/90-tether-vpn \
          /etc/NetworkManager/conf.d/90-tether-vpn-unmanaged.conf
    systemctl daemon-reload; nmcli general reload conf || true
    echo "removed (left /etc/tether-vpn.conf in place)"; exit 0
fi

# tun2socks installed with "go install" lives in the user's ~/go/bin, which
# systemd (and SELinux) won't run from. Copy it somewhere system-wide.
if [[ ! -x /usr/local/bin/tun2socks && ! -x /usr/bin/tun2socks ]]; then
    src=/home/${SUDO_USER:-root}/go/bin/tun2socks
    [[ -x $src ]] || { echo "tun2socks not found; install it first" >&2; exit 1; }
    install -m 755 -o root -g root "$src" /usr/local/bin/tun2socks
    echo "copied $src -> /usr/local/bin/tun2socks"
fi

# install(1) writes new files, so they get the right SELinux labels
install -m 755 -o root -g root bin/tether-vpn /usr/local/sbin/tether-vpn
install -m 644 -o root -g root systemd/tether-vpn.service /etc/systemd/system/tether-vpn.service
install -m 755 -o root -g root networkmanager/90-tether-vpn /etc/NetworkManager/dispatcher.d/90-tether-vpn
install -m 644 -o root -g root networkmanager/90-tether-vpn-unmanaged.conf /etc/NetworkManager/conf.d/
[[ -e /etc/tether-vpn.conf ]] || install -m 644 -o root -g root config/tether-vpn.conf /etc/tether-vpn.conf
restorecon -F /usr/local/sbin/tether-vpn /etc/systemd/system/tether-vpn.service \
    /etc/NetworkManager/dispatcher.d/90-tether-vpn 2>/dev/null || true

systemctl daemon-reload
systemctl enable --now NetworkManager-dispatcher.service >/dev/null 2>&1 || true
nmcli general reload conf || true
echo "installed. Edit /etc/tether-vpn.conf to set your SSID/port."
