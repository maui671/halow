#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/Gateworks/nrc7292.git"
SRC_DIR="/opt/nrc7292"
BOOT_CFG="/boot/firmware/config.txt"
FW_DIR="/lib/firmware"
MOD_NAME="nrc"

SPI_BUS="0"
SPI_CS="0"
SPI_IRQ="5"
SPI_SPEED="20000000"

log(){ echo "[ OK ] $*"; }
warn(){ echo "[WARN] $*"; }
fail(){ echo "[FAIL] $*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || fail "Run as root."

echo "=== NRC7292 HaLow SPI installer for Raspberry Pi 4/5 ==="

apt update
apt install -y \
  git build-essential dkms bc flex bison libssl-dev \
  linux-headers-"$(uname -r)" \
  device-tree-compiler iw wireless-regdb wpasupplicant \
  gpiod kmod

[[ -f "$BOOT_CFG" ]] || fail "Missing $BOOT_CFG"

if [[ -d "$SRC_DIR" ]]; then
  rm -rf "${SRC_DIR}.old"
  mv "$SRC_DIR" "${SRC_DIR}.old"
fi

git clone "$REPO_URL" "$SRC_DIR"

cd "$SRC_DIR/package/src/nrc"
make clean || true
make
[[ -f nrc.ko ]] || fail "nrc.ko did not build"

mkdir -p "/lib/modules/$(uname -r)/extra"
cp -f nrc.ko "/lib/modules/$(uname -r)/extra/nrc.ko"
depmod -a

cp -f "$SRC_DIR/package/evk/sw_pkg/nrc_pkg/sw/firmware/nrc7292_cspi.bin" "$FW_DIR/nrc7292_cspi.bin"
cp -f "$SRC_DIR/package/evk/sw_pkg/nrc_pkg/sw/firmware/nrc7292_bd.dat" "$FW_DIR/bd.dat"

cd "$SRC_DIR"

dtc -@ -I dts -O dtb -o newracom.dtbo dts/newracom_for_5.16_or_later.dts
mkdir -p /boot/firmware/overlays
cp -f newracom.dtbo /boot/firmware/overlays/newracom.dtbo

cp -f "$BOOT_CFG" "$BOOT_CFG.bak.$(date +%Y%m%d-%H%M%S)"

grep -q '^dtparam=spi=on' "$BOOT_CFG" || echo 'dtparam=spi=on' >> "$BOOT_CFG"

sed -i '/^dtoverlay=nrc-rpi/d' "$BOOT_CFG"
sed -i '/^dtoverlay=newracom/d' "$BOOT_CFG"
echo 'dtoverlay=newracom' >> "$BOOT_CFG"

cat > /etc/modprobe.d/nrc7292.conf <<EOF
options nrc fw_name=nrc7292_cspi.bin bd_name=bd.dat spi_bus_num=${SPI_BUS} spi_cs_num=${SPI_CS} spi_gpio_irq=${SPI_IRQ} hifspeed=${SPI_SPEED}
EOF

cat > /etc/modules-load.d/nrc7292.conf <<EOF
nrc
EOF

cat > /usr/local/sbin/nrc7292-check.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

modprobe nrc || true
sleep 3

if iw dev | grep -q 'Interface wlan1'; then
  logger -t nrc7292-check "NRC7292 HaLow interface wlan1 detected"
  exit 0
fi

logger -t nrc7292-check "NRC7292 wlan1 not detected. Recent dmesg follows:"
dmesg -T | grep -iE 'nrc|newracom|spi|firmware|bd.dat|failed' | tail -120 | logger -t nrc7292-check
exit 1
EOF

chmod +x /usr/local/sbin/nrc7292-check.sh

cat > /etc/systemd/system/nrc7292-check.service <<EOF
[Unit]
Description=Verify NRC7292 HaLow SPI interface
After=multi-user.target systemd-modules-load.service
Wants=systemd-modules-load.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nrc7292-check.sh
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable nrc7292-check.service

rmmod nrc 2>/dev/null || true
modprobe nrc || true

echo
echo "=== Current status ==="
dmesg -T | grep -iE 'nrc|newracom|spi|firmware|bd.dat|failed' | tail -120 || true
iw dev || true

echo
log "Install complete. Reboot required."
echo "Run after reboot:"
echo "  iw dev"
echo "  dmesg -T | grep -iE 'nrc|newracom|spi|firmware|bd.dat|failed' | tail -200"
