#!/usr/bin/env bash
set -euo pipefail

BASE="/home/tdcadmin/halow"
VENDOR_DIR="${BASE}/git-cloned-things"
NRC_REPO="${VENDOR_DIR}/nrc7292_sw_pkg"
NRC_PKG="${NRC_REPO}/package/evk/sw_pkg/nrc_pkg"
SCRIPT_DIR="${NRC_PKG}/script"
DRIVER_SRC="${NRC_REPO}/package/src/nrc"
BOOT_DIR="/boot/firmware"
OVERLAY_DIR="${BOOT_DIR}/overlays"
CONFIG_TXT="${BOOT_DIR}/config.txt"

AP_COUNTRY="${AP_COUNTRY:-US}"
AP_CHANNEL="${AP_CHANNEL:-39}"
AP_SECURITY="${AP_SECURITY:-0}"       # 0=open, 1=WPA2-PSK
AP_IP="${AP_IP:-192.168.200.1/24}"
AP_DHCP_START="${AP_DHCP_START:-192.168.200.10}"
AP_DHCP_END="${AP_DHCP_END:-192.168.200.100}"
AP_DHCP_LEASE="${AP_DHCP_LEASE:-12h}"
UPLINK_IF="${UPLINK_IF:-eth0}"

POST_REBOOT="${1:-}"

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root: sudo $0"
    exit 1
  fi
}

apt_install() {
  export DEBIAN_FRONTEND=noninteractive

  if ! dpkg --print-foreign-architectures | grep -qx armhf; then
    dpkg --add-architecture armhf
  fi

  apt update
  apt install -y \
    git build-essential make gcc bc bison flex libssl-dev \
    raspberrypi-kernel-headers device-tree-compiler \
    python3 hostapd dnsmasq iw iproute2 net-tools rfkill \
    wireless-regdb iptables libc6:armhf libstdc++6:armhf
}

ensure_repo() {
  mkdir -p "${VENDOR_DIR}"

  if [[ ! -d "${NRC_REPO}/.git" ]]; then
    git clone https://github.com/newracom/nrc7292_sw_pkg.git "${NRC_REPO}"
  fi

  if [[ ! -d "${NRC_PKG}" ]]; then
    echo "Missing NRC package path: ${NRC_PKG}"
    exit 1
  fi
}

write_overlay() {
  mkdir -p "${OVERLAY_DIR}"

  cat >/tmp/newracom.dts <<'EOF'
/dts-v1/;
/plugin/;

/ {
    compatible = "brcm,bcm2835", "brcm,bcm2708", "brcm,bcm2709", "brcm,bcm2711";

    fragment@0 {
        target = <&spi>;
        __overlay__ {
            pinctrl-names = "default";
            pinctrl-0 = <&nrc_pins>;
            status = "okay";

            spidev@0 {
                status = "disabled";
            };

            spidev@1 {
                status = "disabled";
            };
        };
    };

    fragment@1 {
        target = <&gpio>;
        __overlay__ {
            nrc_pins: nrc_pins {
                brcm,pins = <5 7 8 9 10 11>;
                brcm,function = <0 1 1 4 4 4>;
                brcm,pull = <1 2 2 2 2 1>;
            };
        };
    };

    fragment@2 {
        target = <&spi0>;
        __overlay__ {
            pinctrl-names = "default";
            pinctrl-0 = <&nrc_pins>;
            status = "okay";
            #address-cells = <1>;
            #size-cells = <0>;

            nrc: nrc-cspi@0 {
                compatible = "nrc80211";
                reg = <0>;
                interrupt-parent = <&gpio>;
                interrupts = <5 4>;
                spi-max-frequency = <20000000>;
            };
        };
    };

    __overrides__ {
        max_speed_hz = <&nrc>, "spi-max-frequency:0";
    };
};
EOF

  dtc -@ -I dts -O dtb -o "${OVERLAY_DIR}/newracom.dtbo" /tmp/newracom.dts
}

ensure_config_txt() {
  mkdir -p "${BOOT_DIR}"
  touch "${CONFIG_TXT}"

  sed -i \
    -e '/^dtparam=spi=/d' \
    -e '/^dtoverlay=newracom/d' \
    -e '/^dtoverlay=disable-wifi/d' \
    -e '/^dtoverlay=disable-bt/d' \
    "${CONFIG_TXT}"

  cat >>"${CONFIG_TXT}" <<'EOF'

# HaLow / NRC7292 SPI host mode
dtparam=spi=on
dtoverlay=disable-wifi
dtoverlay=disable-bt
dtoverlay=newracom
EOF

  cat >/etc/modprobe.d/halow-blacklist.conf <<'EOF'
blacklist brcmfmac
blacklist brcmutil
EOF
}

build_driver() {
  if [[ ! -d "${DRIVER_SRC}" ]]; then
    echo "Missing driver source: ${DRIVER_SRC}"
    exit 1
  fi

  make -C "${DRIVER_SRC}" clean || true
  make -C "${DRIVER_SRC}"

  mkdir -p "${NRC_PKG}/sw/driver"
  cp -f "${DRIVER_SRC}/nrc.ko" "${NRC_PKG}/sw/driver/nrc.ko"
}

stage_firmware() {
  mkdir -p "${NRC_PKG}/sw/firmware"

  if [[ ! -f "${NRC_PKG}/sw/firmware/nrc7292_cspi.bin" && -f "${NRC_REPO}/package/evk/binary/nrc7292_cspi.bin" ]]; then
    cp -f "${NRC_REPO}/package/evk/binary/nrc7292_cspi.bin" "${NRC_PKG}/sw/firmware/"
  fi

  if [[ ! -f "${NRC_PKG}/sw/firmware/nrc7292_bd.dat" && -f "${NRC_REPO}/package/evk/binary/nrc7292_bd.dat" ]]; then
    cp -f "${NRC_REPO}/package/evk/binary/nrc7292_bd.dat" "${NRC_PKG}/sw/firmware/"
  fi

  if [[ ! -f "${NRC_PKG}/sw/firmware/nrc7292_cspi.bin" ]]; then
    echo "Missing firmware: nrc7292_cspi.bin"
    exit 1
  fi

  if [[ ! -f "${NRC_PKG}/sw/firmware/nrc7292_bd.dat" ]]; then
    echo "Missing board data: nrc7292_bd.dat"
    exit 1
  fi

  cp -f "${NRC_PKG}/sw/firmware/nrc7292_cspi.bin" /lib/firmware/
  cp -f "${NRC_PKG}/sw/firmware/nrc7292_bd.dat" /lib/firmware/
  cp -f "${NRC_PKG}/sw/firmware/nrc7292_bd.dat" /lib/firmware/bd.dat

  chmod 0644 /lib/firmware/nrc7292_cspi.bin /lib/firmware/nrc7292_bd.dat /lib/firmware/bd.dat
}

patch_vendor_tree() {
  mkdir -p /home/pi
  ln -sfn "${NRC_PKG}" /home/pi/nrc_pkg

  chmod +x /home/pi/nrc_pkg/script/*.py 2>/dev/null || true
  chmod +x /home/pi/nrc_pkg/script/cli_app 2>/dev/null || true
  chmod +x /home/pi/nrc_pkg/sw/firmware/copy 2>/dev/null || true
  chmod +x /home/pi/nrc_pkg/script/conf/etc/*.sh 2>/dev/null || true

  if [[ -f /home/pi/nrc_pkg/script/start.py ]]; then
    cp -n /home/pi/nrc_pkg/script/start.py /home/pi/nrc_pkg/script/start.py.orig || true
    sed -i 's/uni_s1g\.bin/nrc7292_cspi.bin/g' /home/pi/nrc_pkg/script/start.py
  fi

  cat >/etc/modprobe.d/nrc.conf <<'EOF'
options nrc fw_name=nrc7292_cspi.bin bd_name=nrc7292_bd.dat
EOF

  grep -qxF mac80211 /etc/modules || echo mac80211 >>/etc/modules
  grep -qxF cfg80211 /etc/modules || echo cfg80211 >>/etc/modules
}

write_runtime_files() {
  cat >/etc/halow-ap.env <<EOF
AP_COUNTRY=${AP_COUNTRY}
AP_CHANNEL=${AP_CHANNEL}
AP_SECURITY=${AP_SECURITY}
AP_IP=${AP_IP}
AP_DHCP_START=${AP_DHCP_START}
AP_DHCP_END=${AP_DHCP_END}
AP_DHCP_LEASE=${AP_DHCP_LEASE}
UPLINK_IF=${UPLINK_IF}
EOF

  cat >/usr/local/sbin/halow-ap-control <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

source /etc/halow-ap.env

NRC_SCRIPT_DIR="/home/pi/nrc_pkg/script"

start_ap() {
  cd "${NRC_SCRIPT_DIR}"

  ./stop.py 2>/dev/null || true
  pkill -f hostapd 2>/dev/null || true
  pkill -f wpa_supplicant 2>/dev/null || true
  pkill -f "dnsmasq.*wlan0" 2>/dev/null || true

  modprobe cfg80211 || true
  modprobe mac80211 || true
  rmmod nrc 2>/dev/null || true

  python3 start.py 1 "${AP_SECURITY}" "${AP_COUNTRY}" "${AP_CHANNEL}"

  ip link set wlan0 up
  ip addr flush dev wlan0
  ip addr add "${AP_IP}" dev wlan0

  sysctl -w net.ipv4.ip_forward=1 >/dev/null

  iptables -t nat -C POSTROUTING -o "${UPLINK_IF}" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -o "${UPLINK_IF}" -j MASQUERADE

  pkill -f "dnsmasq.*wlan0" 2>/dev/null || true
  dnsmasq \
    --interface=wlan0 \
    --bind-interfaces \
    --dhcp-range="${AP_DHCP_START},${AP_DHCP_END},255.255.255.0,${AP_DHCP_LEASE}" \
    --dhcp-option=3,"${AP_IP%/*}" \
    --dhcp-option=6,8.8.8.8 \
    --log-dhcp

  echo "HaLow AP ready"
  iw dev wlan0 info || true
  ip addr show wlan0 || true
}

stop_ap() {
  cd "${NRC_SCRIPT_DIR}" 2>/dev/null || true

  pkill -f "dnsmasq.*wlan0" 2>/dev/null || true
  pkill -f hostapd 2>/dev/null || true
  pkill -f wpa_supplicant 2>/dev/null || true

  ./stop.py 2>/dev/null || true

  iptables -t nat -D POSTROUTING -o "${UPLINK_IF}" -j MASQUERADE 2>/dev/null || true
  ip addr flush dev wlan0 2>/dev/null || true
  ip link set wlan0 down 2>/dev/null || true
  rmmod nrc 2>/dev/null || true
}

case "${1:-}" in
  start) start_ap ;;
  stop) stop_ap ;;
  restart) stop_ap; start_ap ;;
  *)
    echo "Usage: $0 {start|stop|restart}"
    exit 2
    ;;
esac
EOF

  chmod 0755 /usr/local/sbin/halow-ap-control

  cat >/etc/systemd/system/halow-ap.service <<'EOF'
[Unit]
Description=NRC7292 HaLow AP
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
EnvironmentFile=/etc/halow-ap.env
ExecStart=/usr/local/sbin/halow-ap-control start
ExecStop=/usr/local/sbin/halow-ap-control stop
TimeoutStartSec=90

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable halow-ap.service
}

spi_overlay_active() {
  [[ -e /sys/bus/spi/devices/spi0.0/modalias ]] && grep -q 'spi:nrc80211' /sys/bus/spi/devices/spi0.0/modalias
}

maybe_reboot_for_overlay() {
  if spi_overlay_active; then
    return 0
  fi

  if [[ "${POST_REBOOT}" == "--post-reboot" ]]; then
    echo "SPI overlay still not active after reboot."
    echo "Check /boot/firmware/config.txt and wiring/DIP switches."
    exit 1
  fi

  cat >/etc/systemd/system/halow-ap-firstboot.service <<EOF
[Unit]
Description=Finish NRC7292 HaLow AP install after reboot
After=multi-user.target

[Service]
Type=oneshot
ExecStart=${BASE}/install-ap.sh --post-reboot
ExecStartPost=/bin/systemctl disable halow-ap-firstboot.service
ExecStartPost=/bin/rm -f /etc/systemd/system/halow-ap-firstboot.service

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable halow-ap-firstboot.service

  echo "SPI overlay requires reboot. Rebooting now; install will finish automatically."
  reboot
}

start_service() {
  systemctl restart halow-ap.service
  systemctl status halow-ap.service --no-pager || true

  echo
  echo "Validation:"
  iw dev || true
  ip addr show wlan0 || true
  pgrep -a hostapd || true
  pgrep -a dnsmasq || true
}

main() {
  require_root
  apt_install
  ensure_repo
  write_overlay
  ensure_config_txt
  build_driver
  stage_firmware
  patch_vendor_tree
  write_runtime_files
  maybe_reboot_for_overlay
  start_service
}

main "$@"
