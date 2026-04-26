#!/usr/bin/env bash
set -Eeuo pipefail

# Skylens TAP HaLow transport installer for Raspberry Pi 4B/5.
# Assumes an NRC7292/Newracom SPI module wired to the Pi GPIO header:
#   SPI0 MOSI/MISO/SCLK, CE0, 3V3/GND, and GPIO5 for IRQ by default.

REPO_URL="${HALOW_REPO_URL:-https://github.com/Gateworks/nrc7292.git}"
SRC_DIR="${HALOW_SRC_DIR:-/opt/nrc7292}"
BOOT_CFG="${HALOW_BOOT_CONFIG:-/boot/firmware/config.txt}"
FW_DIR="${HALOW_FIRMWARE_DIR:-/lib/firmware}"
OVERLAY_NAME="${HALOW_OVERLAY_NAME:-newracom}"
IFACE="${HALOW_INTERFACE:-wlan1}"

SPI_BUS="${HALOW_SPI_BUS:-0}"
SPI_CS="${HALOW_SPI_CS:-0}"
SPI_IRQ="${HALOW_SPI_IRQ:-5}"
SPI_SPEED="${HALOW_SPI_SPEED:-10000000}"
# NRC7292 Pi HAT/EVK-style modules commonly need power-enable and reset sequencing
# before the nrc driver probes the SPI target. Override these with HALOW_* env vars
# if your carrier uses different pins, or set them empty to disable.
RESET_GPIO="${HALOW_RESET_GPIO:-17}"
RESET_ACTIVE_LOW="${HALOW_RESET_ACTIVE_LOW:-0}"
ENABLE_GPIO="${HALOW_ENABLE_GPIO:-27}"
ENABLE_ACTIVE_HIGH="${HALOW_ENABLE_ACTIVE_HIGH:-1}"

# Conservative speed used while proving the SPI link. Raise HALOW_SPI_PROBE_SPEED
# later if the module probes cleanly and your wiring is stable.
SPI_PROBE_SPEED="${HALOW_SPI_PROBE_SPEED:-1000000}"

HALOW_ADDRESS="${HALOW_ADDRESS:-}"
HALOW_GATEWAY="${HALOW_GATEWAY:-}"
HALOW_DNS="${HALOW_DNS:-}"
HALOW_SSID="${HALOW_SSID:-}"
HALOW_PSK="${HALOW_PSK:-}"
HALOW_ROUTE_METRIC="${HALOW_ROUTE_METRIC:-50}"

log() { echo "[ OK ] $*"; }
info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; }
fail() { echo "[FAIL] $*" >&2; exit 1; }

usage() {
  cat <<USAGE
Usage: sudo env [options] ./scripts/install-halow-transport.sh

Options are supplied as environment variables:
  HALOW_INTERFACE=wlan1              Linux interface created by the driver
  HALOW_SPI_IRQ=5                    GPIO IRQ pin on the Pi header
  HALOW_SPI_SPEED=10000000           Runtime SPI bus speed in Hz
  HALOW_SPI_PROBE_SPEED=1000000       Conservative speed used during first probe
  HALOW_RESET_GPIO=17                Module reset GPIO; empty disables reset control
  HALOW_RESET_ACTIVE_LOW=0           Reset GPIO polarity, 1 means pulse low
  HALOW_ENABLE_GPIO=27               Module enable/power GPIO; empty disables enable control
  HALOW_ENABLE_ACTIVE_HIGH=1         Enable GPIO polarity, 1 means high enables
  HALOW_ADDRESS=10.42.0.2/24         Optional static address
  HALOW_GATEWAY=10.42.0.1            Optional default gateway
  HALOW_DNS=10.42.0.1                Optional DNS server
  HALOW_SSID=field-halow             Optional station SSID for wpa_supplicant
  HALOW_PSK='change-me'              Optional station PSK

This installer is safe to re-run. It backs up boot config before changing it.
USAGE
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || fail "Run as root with sudo."
}

detect_pi() {
  local model=""
  if [[ -r /proc/device-tree/model ]]; then
    model="$(tr -d '\0' </proc/device-tree/model)"
  fi
  case "${model}" in
    *"Raspberry Pi 4"*|*"Raspberry Pi 5"*) log "Detected ${model}" ;;
    *"Raspberry Pi"*) warn "Detected ${model}; this script is tuned for Pi 4B/5 GPIO wiring." ;;
    "") warn "Could not detect Raspberry Pi model; continuing for image build/offline install." ;;
    *) fail "Unsupported board '${model}'. This transport profile assumes Raspberry Pi GPIO SPI wiring." ;;
  esac
}

install_packages() {
  command -v apt-get >/dev/null 2>&1 || fail "apt-get not found; use Raspberry Pi OS/Debian."
  info "Installing HaLow build/runtime dependencies..."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    git build-essential dkms bc flex bison libssl-dev \
    device-tree-compiler iw wireless-regdb \
    wpasupplicant gpiod kmod iproute2 netcat-openbsd

  DEBIAN_FRONTEND=noninteractive apt-get install -y "linux-headers-$(uname -r)" \
    || DEBIAN_FRONTEND=noninteractive apt-get install -y raspberrypi-kernel-headers \
    || warn "Kernel headers were not installed; driver build may fail until headers are available."
}

ensure_boot_config() {
  [[ -f "${BOOT_CFG}" ]] || fail "Missing ${BOOT_CFG}; set HALOW_BOOT_CONFIG if your Pi uses another path."
  cp -f "${BOOT_CFG}" "${BOOT_CFG}.bak.halow.$(date +%Y%m%d-%H%M%S)"

  grep -q '^dtparam=spi=on' "${BOOT_CFG}" || echo 'dtparam=spi=on' >> "${BOOT_CFG}"
  sed -i '/^dtoverlay=nrc-rpi/d;/^dtoverlay=newracom/d' "${BOOT_CFG}"
  echo "dtoverlay=${OVERLAY_NAME}" >> "${BOOT_CFG}"
  log "Boot overlay configured in ${BOOT_CFG}"
}

build_driver() {
  if [[ -d "${SRC_DIR}" ]]; then
    rm -rf "${SRC_DIR}.old"
    mv "${SRC_DIR}" "${SRC_DIR}.old"
  fi

  info "Cloning NRC7292 driver from ${REPO_URL}..."
  git clone --depth 1 "${REPO_URL}" "${SRC_DIR}"

  info "Building nrc kernel module..."
  cd "${SRC_DIR}/package/src/nrc"
  make clean || true
  make
  [[ -f nrc.ko ]] || fail "nrc.ko did not build"

  install -d "/lib/modules/$(uname -r)/extra"
  install -m 0644 nrc.ko "/lib/modules/$(uname -r)/extra/nrc.ko"
  depmod -a
  log "Kernel module installed"
}

install_firmware_and_overlay() {
  install -d "${FW_DIR}" /boot/firmware/overlays
  install -m 0644 "${SRC_DIR}/package/evk/sw_pkg/nrc_pkg/sw/firmware/nrc7292_cspi.bin" "${FW_DIR}/nrc7292_cspi.bin"
  install -m 0644 "${SRC_DIR}/package/evk/sw_pkg/nrc_pkg/sw/firmware/nrc7292_bd.dat" "${FW_DIR}/nrc7292_bd.dat"
  ln -sf nrc7292_bd.dat "${FW_DIR}/bd.dat"

  local dts_path="/tmp/${OVERLAY_NAME}-nrc7292.dts"
  local dtbo_path="/tmp/${OVERLAY_NAME}.dtbo"

  cat > "${dts_path}" <<EOF
/dts-v1/;
/plugin/;

/ {
    compatible = "brcm,bcm2712", "brcm,bcm2711", "brcm,bcm2835";

    fragment@0 {
        target = <&spi0>;
        __overlay__ {
            status = "okay";
            #address-cells = <1>;
            #size-cells = <0>;

            nrc: nrc-cspi@${SPI_CS} {
                compatible = "nrc80211";
                reg = <${SPI_CS}>;
                interrupt-parent = <&gpio>;
                interrupts = <${SPI_IRQ} 4>;
                spi-max-frequency = <${SPI_SPEED}>;
                status = "okay";
            };
        };
    };

    fragment@1 {
        target = <&spidev${SPI_CS}>;
        __overlay__ {
            status = "disabled";
        };
    };
};
EOF

  dtc -@ -I dts -O dtb -o "${dtbo_path}" "${dts_path}"
  install -m 0644 "${dtbo_path}" "/boot/firmware/overlays/${OVERLAY_NAME}.dtbo"
  rm -f "${dts_path}" "${dtbo_path}"
  log "Firmware and Raspberry Pi 4/5 device-tree overlay installed"
}

write_module_config() {
  cat > /etc/modprobe.d/nrc7292.conf <<EOF
options nrc fw_name=nrc7292_cspi.bin bd_name=nrc7292_bd.dat spi_bus_num=${SPI_BUS} spi_cs_num=${SPI_CS} spi_gpio_irq=${SPI_IRQ} hifspeed=${SPI_PROBE_SPEED} spi_polling_interval=5
install nrc /usr/local/sbin/halow-reset-pre; /sbin/modprobe --ignore-install nrc
EOF
  rm -f /etc/modules-load.d/nrc7292.conf
  log "Module options written for SPI${SPI_BUS}.${SPI_CS}, IRQ GPIO${SPI_IRQ}"
}

write_reset_script() {
  cat > /usr/local/sbin/halow-reset-pre <<EOF
#!/usr/bin/env bash
set -euo pipefail

RESET_GPIO="${RESET_GPIO}"
RESET_ACTIVE_LOW="${RESET_ACTIVE_LOW}"
ENABLE_GPIO="${ENABLE_GPIO}"
ENABLE_ACTIVE_HIGH="${ENABLE_ACTIVE_HIGH}"

set_gpio() {
  local gpio="\$1"
  local value="\$2"
  [[ -n "\${gpio}" ]] || return 0

  if command -v pinctrl >/dev/null 2>&1; then
    if [[ "\${value}" = "1" ]]; then
      pinctrl set "\${gpio}" op dh
    else
      pinctrl set "\${gpio}" op dl
    fi
    return 0
  fi

  if command -v raspi-gpio >/dev/null 2>&1; then
    if [[ "\${value}" = "1" ]]; then
      raspi-gpio set "\${gpio}" op dh
    else
      raspi-gpio set "\${gpio}" op dl
    fi
    return 0
  fi

  return 0
}

if [[ -n "\${ENABLE_GPIO}" ]]; then
  if [[ "\${ENABLE_ACTIVE_HIGH}" = "1" ]]; then
    set_gpio "\${ENABLE_GPIO}" 1
  else
    set_gpio "\${ENABLE_GPIO}" 0
  fi
  sleep 0.2
fi

if [[ -n "\${RESET_GPIO}" ]]; then
  if [[ "\${RESET_ACTIVE_LOW}" = "0" ]]; then
    set_gpio "\${RESET_GPIO}" 0
    sleep 0.2
    set_gpio "\${RESET_GPIO}" 1
  else
    set_gpio "\${RESET_GPIO}" 1
    sleep 0.2
    set_gpio "\${RESET_GPIO}" 0
  fi
  sleep 0.8
fi
EOF
  chmod +x /usr/local/sbin/halow-reset-pre
}

write_wpa_config() {
  [[ -n "${HALOW_SSID}" ]] || return 0
  [[ -n "${HALOW_PSK}" ]] || fail "HALOW_SSID was set but HALOW_PSK is empty."

  install -d /etc/wpa_supplicant
  umask 077
  cat > "/etc/wpa_supplicant/wpa_supplicant-${IFACE}.conf" <<EOF
ctrl_interface=DIR=/run/wpa_supplicant GROUP=netdev
update_config=0
country=US

network={
    ssid="${HALOW_SSID}"
    psk="${HALOW_PSK}"
    key_mgmt=WPA-PSK
}
EOF
  umask 022
  systemctl enable "wpa_supplicant@${IFACE}.service" >/dev/null 2>&1 || true
  log "wpa_supplicant configured for ${IFACE}"
}

write_transport_up_script() {
  cat > /usr/local/sbin/halow-transport-up <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

IFACE="${IFACE}"
ADDRESS="${HALOW_ADDRESS}"
GATEWAY="${HALOW_GATEWAY}"
DNS="${HALOW_DNS}"
ROUTE_METRIC="${HALOW_ROUTE_METRIC}"

/usr/local/sbin/halow-reset-pre || true
rmmod nrc 2>/dev/null || true
if ! modprobe nrc; then
  echo "modprobe nrc failed" >&2
  dmesg -T | grep -iE 'nrc|newracom|spi|firmware|bd.dat|failed|error|ack|target' | tail -160 >&2 || true
  exit 1
fi

if ! ls /sys/bus/spi/devices/spi${SPI_BUS}.${SPI_CS} >/dev/null 2>&1; then
  echo "SPI device spi${SPI_BUS}.${SPI_CS} is missing; check dtoverlay=${OVERLAY_NAME} and reboot" >&2
else
  echo "SPI device spi${SPI_BUS}.${SPI_CS} exists"
  if [[ -e /sys/bus/spi/devices/spi${SPI_BUS}.${SPI_CS}/driver ]]; then
    echo "SPI driver: \$(basename "\$(readlink -f /sys/bus/spi/devices/spi${SPI_BUS}.${SPI_CS}/driver)")"
  else
    echo "SPI driver: none"
  fi
fi

if [[ ! -e /sys/bus/spi/devices/spi${SPI_BUS}.${SPI_CS}/driver ]]; then
  echo "SPI target spi${SPI_BUS}.${SPI_CS} exists but nrc80211 did not bind; reset/enable/IRQ/CS wiring is still wrong or the module is not powered" >&2
  dmesg -T | grep -iE 'nrc|newracom|spi|firmware|bd.dat|failed|error|ack|target' | tail -160 >&2 || true
  exit 1
fi

for _ in \$(seq 1 90); do
  if ip link show "\${IFACE}" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

ip link show "\${IFACE}" >/dev/null 2>&1 || {
  echo "HaLow interface \${IFACE} did not appear" >&2
  dmesg -T | grep -iE 'nrc|newracom|spi|firmware|bd.dat|failed' | tail -120 >&2 || true
  exit 1
}

ip link set "\${IFACE}" up
iw dev "\${IFACE}" set power_save off 2>/dev/null || true

if [[ -n "\${ADDRESS}" ]]; then
  ip addr replace "\${ADDRESS}" dev "\${IFACE}"
fi

if [[ -n "\${GATEWAY}" ]]; then
  ip route replace default via "\${GATEWAY}" dev "\${IFACE}" metric "\${ROUTE_METRIC}"
fi

if [[ -n "\${DNS}" ]] && command -v resolvectl >/dev/null 2>&1; then
  resolvectl dns "\${IFACE}" "\${DNS}" || true
fi

ip -brief addr show "\${IFACE}"
EOF
  chmod +x /usr/local/sbin/halow-transport-up
}

write_debug_script() {
  cat > /usr/local/sbin/halow-transport-debug <<EOF
#!/usr/bin/env bash
set -euo pipefail

IFACE="${IFACE}"
SPI_DEV="spi${SPI_BUS}.${SPI_CS}"

echo "== boot config =="
grep -nE 'dtparam=spi|dtoverlay=.*(newracom|nrc|spi)' "${BOOT_CFG}" || true
echo
echo "== overlay =="
ls -l /boot/firmware/overlays/${OVERLAY_NAME}.dtbo 2>/dev/null || true
echo
echo "== configured target =="
echo "interface: \${IFACE}"
echo "spi device: \${SPI_DEV}"
echo "irq gpio: ${SPI_IRQ}"
echo "spi speed: ${SPI_SPEED}"
echo "reset gpio: ${RESET_GPIO:-none}"
echo "enable gpio: ${ENABLE_GPIO:-none}"
echo
echo "== modules =="
lsmod | grep -E '^nrc|^mac80211|^cfg80211' || true
modinfo nrc 2>/dev/null | sed -n '1,120p' || true
echo
echo "== firmware files =="
ls -l /lib/firmware/nrc7292_cspi.bin /lib/firmware/nrc7292_bd.dat /lib/firmware/bd.dat 2>/dev/null || true
echo
echo "== module config =="
cat /etc/modprobe.d/nrc7292.conf 2>/dev/null || true
echo
echo "== spi devices =="
find /sys/bus/spi/devices -maxdepth 2 -type l -o -type d 2>/dev/null | sort || true
if [[ -e "/sys/bus/spi/devices/\${SPI_DEV}/driver" ]]; then
  echo "driver for \${SPI_DEV}: \$(basename "\$(readlink -f "/sys/bus/spi/devices/\${SPI_DEV}/driver")")"
else
  echo "driver for \${SPI_DEV}: none"
fi
echo
echo "== netdevs =="
ip -brief link
echo
echo "== iw =="
iw dev || true
echo
echo "== recent kernel messages =="
dmesg -T | grep -iE 'nrc|newracom|nrc80211|spi|firmware|bd.dat|failed|error' | tail -200 || true
EOF
  chmod +x /usr/local/sbin/halow-transport-debug
}

write_systemd_units() {
  cat > /etc/systemd/system/halow-transport.service <<EOF
[Unit]
Description=HaLow transport link (${IFACE})
After=systemd-modules-load.service network-pre.target
Wants=systemd-modules-load.service network-pre.target
Before=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/halow-transport-up
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/halow-transport-check.service <<EOF
[Unit]
Description=Verify HaLow transport link (${IFACE})
After=halow-transport.service network-online.target
Wants=halow-transport.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'ip link show ${IFACE} && iw dev ${IFACE} info || true'

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable halow-transport.service halow-transport-check.service
  log "systemd services enabled"
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  require_root
  detect_pi
  install_packages
  build_driver
  install_firmware_and_overlay
  ensure_boot_config
  write_module_config
  write_reset_script
  write_wpa_config
  write_transport_up_script
  write_debug_script
  write_systemd_units

  rmmod nrc 2>/dev/null || true
  /usr/local/sbin/halow-reset-pre || true
  if ! modprobe nrc; then
    warn "nrc probe failed during install. Reboot, then run: halow-transport-debug"
  fi
  systemctl restart "wpa_supplicant@${IFACE}.service" 2>/dev/null || true
  systemctl restart halow-transport.service 2>/dev/null || true

  echo
  log "HaLow transport install complete. Reboot is recommended before field use."
  echo "Verify after reboot:"
  echo "  ip -brief addr show ${IFACE}"
  echo "  iw dev ${IFACE} info"
  echo "  journalctl -u halow-transport -u halow-transport-check --no-pager -n 100"
}

main "$@"
