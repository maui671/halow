#!/usr/bin/env bash
set -Eeuo pipefail

BOOT_CONFIG="/boot/firmware/config.txt"

log(){ echo "[+] $*"; }
warn(){ echo "[!] $*" >&2; }

[[ "${EUID}" -eq 0 ]] || { echo "[ERROR] Run as root/sudo."; exit 1; }

log "Stopping services"
systemctl disable --now halow 2>/dev/null || true
systemctl stop dnsmasq 2>/dev/null || true
pkill hostapd 2>/dev/null || true
pkill dnsmasq 2>/dev/null || true
rmmod nrc 2>/dev/null || true

log "Removing systemd service and control scripts"
rm -f /etc/systemd/system/halow.service
rm -f /usr/local/sbin/halow-start
rm -f /usr/local/sbin/halow-stop
rm -f /usr/local/sbin/halow-status
systemctl daemon-reload

log "Removing runtime/config files"
rm -rf /opt/nrc_pkg
rm -rf /home/pi/nrc_pkg
rm -f /etc/halow.conf
rm -f /etc/dnsmasq.d/halow.conf

log "Removing kernel module and overlay"
rm -f "/lib/modules/$(uname -r)/extra/nrc.ko"
rm -f /boot/firmware/overlays/newracom.dtbo
depmod -a || true

if [[ -f "${BOOT_CONFIG}" ]]; then
  log "Cleaning boot config"
  cp -a "${BOOT_CONFIG}" "${BOOT_CONFIG}.bak.uninstall.$(date +%Y%m%d-%H%M%S)"
  sed -i \
    -e '/^# NRC7292 HaLow host mode/d' \
    -e '/^dtparam=spi=on/d' \
    -e '/^dtoverlay=newracom/d' \
    -e '/^dtoverlay=disable-bt/d' \
    -e '/^dtoverlay=disable-wifi/d' \
    -e '/^dtoverlay=disable-spidev/d' \
    "${BOOT_CONFIG}"
fi

cat <<EOF

[+] Uninstall complete.

Optional source cleanup:

  sudo rm -rf /opt/nrc7292

Reboot recommended:

  sudo reboot

EOF
