#!/usr/bin/env bash
set -Eeuo pipefail

SRC_DIR="/opt/nrc7292"
BOOT_CFG="/boot/firmware/config.txt"

[[ "$(id -u)" -eq 0 ]] || {
  echo "[FAIL] Run as root." >&2
  exit 1
}

echo "=== NRC7292 HaLow SPI uninstaller ==="

systemctl disable --now hostapd 2>/dev/null || true
systemctl disable --now dnsmasq 2>/dev/null || true
systemctl disable --now halow-wlan1-ip.service 2>/dev/null || true

rm -f /etc/systemd/system/halow-wlan1-ip.service
rm -f /etc/hostapd/hostapd-halow.conf
rm -f /etc/dnsmasq.d/halow.conf

systemctl daemon-reload || true

rmmod nrc 2>/dev/null || true

rm -f /etc/modules-load.d/nrc7292.conf
rm -f /etc/modprobe.d/nrc7292.conf

rm -f "/lib/modules/$(uname -r)/extra/nrc.ko"
depmod -a || true

rm -f /lib/firmware/nrc7292_cspi.bin
rm -f /lib/firmware/bd.dat

rm -f /boot/firmware/overlays/newracom.dtbo

if [[ -f "${BOOT_CFG}" ]]; then
  cp -f "${BOOT_CFG}" "${BOOT_CFG}.bak.uninstall.$(date +%Y%m%d-%H%M%S)"
  sed -i '/^dtoverlay=newracom/d' "${BOOT_CFG}"
fi

if [[ -d "${SRC_DIR}" ]]; then
  rm -rf "${SRC_DIR}"
fi

echo
echo "[ OK ] NRC7292 HaLow SPI files removed."
echo
echo "Recommended:"
echo "  reboot"
echo
echo "This did not remove shared packages like git, build-essential, iw, hostapd, or dnsmasq."
