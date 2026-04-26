#!/usr/bin/env bash
set -Eeuo pipefail

SRC_DIR="${HALOW_SRC_DIR:-/opt/nrc7292}"
BOOT_CFG="${HALOW_BOOT_CONFIG:-/boot/firmware/config.txt}"
OVERLAY_NAME="${HALOW_OVERLAY_NAME:-newracom}"
IFACE="${HALOW_INTERFACE:-wlan1}"

fail() { echo "[FAIL] $*" >&2; exit 1; }
log() { echo "[ OK ] $*"; }
warn() { echo "[WARN] $*"; }

[[ "${EUID}" -eq 0 ]] || fail "Run as root with sudo."

systemctl disable --now halow-transport-check.service 2>/dev/null || true
systemctl disable --now halow-transport.service 2>/dev/null || true
systemctl disable --now "wpa_supplicant@${IFACE}.service" 2>/dev/null || true

rm -f /etc/systemd/system/halow-transport-check.service
rm -f /etc/systemd/system/halow-transport.service
rm -f /usr/local/sbin/halow-transport-up
rm -f /usr/local/sbin/halow-transport-debug
rm -f /usr/local/sbin/halow-reset-pre
rm -f "/etc/wpa_supplicant/wpa_supplicant-${IFACE}.conf"

rmmod nrc 2>/dev/null || true

rm -f /etc/modules-load.d/nrc7292.conf
rm -f /etc/modprobe.d/nrc7292.conf
rm -f "/lib/modules/$(uname -r)/extra/nrc.ko"
depmod -a || true

rm -f /lib/firmware/nrc7292_cspi.bin
rm -f /lib/firmware/bd.dat
rm -f "/boot/firmware/overlays/${OVERLAY_NAME}.dtbo"

if [[ -f "${BOOT_CFG}" ]]; then
  cp -f "${BOOT_CFG}" "${BOOT_CFG}.bak.halow-uninstall.$(date +%Y%m%d-%H%M%S)"
  sed -i '/^dtoverlay=nrc-rpi/d;/^dtoverlay=newracom/d' "${BOOT_CFG}"
  log "Removed HaLow overlays from ${BOOT_CFG}"
else
  warn "Boot config not found at ${BOOT_CFG}"
fi

rm -rf "${SRC_DIR}"
systemctl daemon-reload || true
systemctl reset-failed halow-transport.service halow-transport-check.service 2>/dev/null || true

echo
log "HaLow transport files removed. Reboot to unload all boot-time state."
