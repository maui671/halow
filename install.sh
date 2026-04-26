#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="${HALOW_REPO_URL:-https://github.com/Gateworks/nrc7292.git}"
SRC_DIR="${HALOW_SRC_DIR:-/opt/nrc7292}"
BOOT_CFG="${HALOW_BOOT_CONFIG:-/boot/firmware/config.txt}"
FW_DIR="${HALOW_FIRMWARE_DIR:-/lib/firmware}"
OVERLAY_NAME="${HALOW_OVERLAY_NAME:-newracom}"
IFACE="${HALOW_INTERFACE:-wlan1}"

SPI_BUS="${HALOW_SPI_BUS:-0}"
SPI_CS="${HALOW_SPI_CS:-1}"
SPI_IRQ="${HALOW_SPI_IRQ:-5}"

# Lower default for Pi3 stability
SPI_SPEED="${HALOW_SPI_SPEED:-500000}"

RESET_GPIO="${HALOW_RESET_GPIO:-17}"
RESET_ACTIVE_LOW="${HALOW_RESET_ACTIVE_LOW:-0}"

log() { echo "[ OK ] $*"; }
info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
fail() { echo "[FAIL] $*" >&2; exit 1; }

require_root() {
  [[ "${EUID}" -eq 0 ]] || fail "Run as root."
}

detect_pi() {
  MODEL="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || echo unknown)"

  case "$MODEL" in
    *"Raspberry Pi 3"*)
      PI_GEN=3
      ;;
    *"Raspberry Pi 4"*)
      PI_GEN=4
      ;;
    *"Raspberry Pi 5"*)
      PI_GEN=5
      ;;
    *)
      PI_GEN=unknown
      ;;
  esac

  log "Detected: $MODEL"

  if [[ "$PI_GEN" == "3" ]]; then
    warn "Pi 3 detected: lowering SPI speed for stability"
    SPI_SPEED="${HALOW_SPI_SPEED:-500000}"
  fi
}

evk_power_warning() {
cat <<EOF

[IMPORTANT]
nRM7292 Test Board requires external 5V power.

Without proper board power:
  SPI ACK invalid
  Target not ready

EOF
}

install_packages() {
  apt-get update || true
  apt-get install -y \
    git build-essential dkms bc flex bison libssl-dev \
    device-tree-compiler iw wireless-regdb wpasupplicant \
    gpiod kmod iproute2 netcat-openbsd
}

build_driver() {
  rm -rf "$SRC_DIR"
  git clone --depth 1 "$REPO_URL" "$SRC_DIR"

  cd "$SRC_DIR/package/src/nrc"
  make clean || true
  make

  install -d "/lib/modules/$(uname -r)/extra"
  install -m 0644 nrc.ko "/lib/modules/$(uname -r)/extra/"
  depmod -a
}

install_fw_overlay() {
  install -d "$FW_DIR" /boot/firmware/overlays

  cp "$SRC_DIR/package/evk/sw_pkg/nrc_pkg/sw/firmware/nrc7292_cspi.bin" "$FW_DIR/"
  cp "$SRC_DIR/package/evk/sw_pkg/nrc_pkg/sw/firmware/nrc7292_bd.dat" "$FW_DIR/"
  ln -sf "$FW_DIR/nrc7292_bd.dat" "$FW_DIR/bd.dat"

cat > /tmp/nrc.dts <<EOF
/dts-v1/;
/plugin/;

/ {
    compatible = "brcm,bcm2835","brcm,bcm2711","brcm,bcm2712";

    fragment@0 {
        target = <&spi0>;
        __overlay__ {
            status = "okay";

            nrc@${SPI_CS} {
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

  dtc -@ -I dts -O dtb -o "/boot/firmware/overlays/${OVERLAY_NAME}.dtbo" /tmp/nrc.dts
}

update_boot() {
  grep -q "dtparam=spi=on" "$BOOT_CFG" || echo "dtparam=spi=on" >> "$BOOT_CFG"

  sed -i '/dtoverlay=newracom/d' "$BOOT_CFG"
  echo "dtoverlay=${OVERLAY_NAME}" >> "$BOOT_CFG"
}

write_modprobe() {
cat > /etc/modprobe.d/nrc.conf <<EOF
options nrc \
fw_name=nrc7292_cspi.bin \
bd_name=nrc7292_bd.dat \
spi_bus_num=${SPI_BUS} \
spi_cs_num=${SPI_CS} \
spi_gpio_irq=${SPI_IRQ} \
hifspeed=${SPI_SPEED} \
spi_polling_interval=5
EOF
}

write_service() {
cat > /etc/systemd/system/halow.service <<EOF
[Unit]
Description=HaLow bring-up
After=network-pre.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/halow-up
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

cat > /usr/local/bin/halow-up <<EOF
#!/bin/bash
set -e

rmmod nrc 2>/dev/null || true
modprobe nrc || true

sleep 3

if ! ip link show ${IFACE} >/dev/null 2>&1; then
  echo "FAIL: wlan1 not created"
  dmesg | tail -50
  exit 1
fi

ip link set ${IFACE} up
ip -brief addr show ${IFACE}
EOF

chmod +x /usr/local/bin/halow-up

systemctl daemon-reload
systemctl enable halow.service
}

main() {
  require_root
  detect_pi
  evk_power_warning
  install_packages
  build_driver
  install_fw_overlay
  update_boot
  write_modprobe
  write_service

  log "Install complete. Reboot required."
}

main
