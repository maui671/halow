#!/usr/bin/env bash
set -euo pipefail

BASE="/home/tdcadmin/halow"
BOOT_DIR="/boot/firmware"
CONFIG_TXT="${BOOT_DIR}/config.txt"

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root: sudo $0"
    exit 1
  fi
}

stop_services() {
  systemctl disable --now halow-ap.service 2>/dev/null || true
  systemctl disable --now halow-ap-firstboot.service 2>/dev/null || true

  pkill -f "dnsmasq.*wlan0" 2>/dev/null || true
  pkill -f hostapd 2>/dev/null || true
  pkill -f wpa_supplicant 2>/dev/null || true

  /home/pi/nrc_pkg/script/stop.py 2>/dev/null || true

  ip addr flush dev wlan0 2>/dev/null || true
  ip link set wlan0 down 2>/dev/null || true

  rmmod nrc 2>/dev/null || true
}

remove_runtime_files() {
  rm -f /etc/systemd/system/halow-ap.service
  rm -f /etc/systemd/system/halow-ap-firstboot.service
  rm -f /usr/local/sbin/halow-ap-control
  rm -f /etc/halow-ap.env

  systemctl daemon-reload
}

remove_kernel_config() {
  rm -f /etc/modprobe.d/nrc.conf
  rm -f /etc/modprobe.d/halow-blacklist.conf

  sed -i '/^mac80211$/d' /etc/modules 2>/dev/null || true
  sed -i '/^cfg80211$/d' /etc/modules 2>/dev/null || true
  sed -i '/^nrc$/d' /etc/modules 2>/dev/null || true
}

remove_boot_overlay_config() {
  if [[ -f "${CONFIG_TXT}" ]]; then
    sed -i \
      -e '/# HaLow \/ NRC7292 SPI host mode/d' \
      -e '/^dtparam=spi=on$/d' \
      -e '/^dtoverlay=newracom$/d' \
      -e '/^dtoverlay=disable-wifi$/d' \
      -e '/^dtoverlay=disable-bt$/d' \
      "${CONFIG_TXT}"
  fi

  rm -f "${BOOT_DIR}/overlays/newracom.dtbo"
}

remove_firmware_staging() {
  rm -f /lib/firmware/nrc7292_cspi.bin
  rm -f /lib/firmware/nrc7292_bd.dat
  rm -f /lib/firmware/bd.dat

  rm -f /home/pi/nrc_pkg
}

remove_nat_rule() {
  iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null || true
}

main() {
  require_root
  stop_services
  remove_nat_rule
  remove_runtime_files
  remove_kernel_config
  remove_boot_overlay_config
  remove_firmware_staging

  echo "HaLow AP removed. Reboot recommended."
}

main "$@"
