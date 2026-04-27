#!/usr/bin/env bash
set -Eeuo pipefail

APP="nrc7292-halow"
SRC_DIR="/opt/nrc7292"
RUNTIME_DIR="/opt/nrc_pkg"
LEGACY_RUNTIME="/home/pi/nrc_pkg"
CONF="/etc/halow.conf"
BOOT_CONFIG="/boot/firmware/config.txt"
OVERLAY_DIR="/boot/firmware/overlays"
SERVICE="halow.service"

log(){ echo "[+] $*"; }
warn(){ echo "[!] $*" >&2; }
die(){ echo "[ERROR] $*" >&2; exit 1; }

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run with sudo/root."
}

detect_pi() {
  tr -d '\0' < /proc/device-tree/model 2>/dev/null || true
}

require_pi45() {
  local model
  model="$(detect_pi)"
  echo "Detected: ${model}"
  grep -qiE 'Raspberry Pi (4|5)' <<<"${model}" || die "This installer is intended for Raspberry Pi 4 or 5."
}

ask() {
  local prompt="$1"
  local default="$2"
  local var
  read -r -p "${prompt} [${default}]: " var
  echo "${var:-$default}"
}

prompt_config() {
  echo
  echo "HaLow role:"
  echo "  1) AP"
  echo "  2) Client/STA"
  read -r -p "Select role [1]: " ROLE_SEL
  ROLE_SEL="${ROLE_SEL:-1}"

  case "${ROLE_SEL}" in
    1) ROLE="ap" ;;
    2) ROLE="sta" ;;
    *) die "Invalid role." ;;
  esac

  COUNTRY="$(ask "Country code" "US")"
  SSID="$(ask "HaLow SSID" "HALOW-MAUI")"

  echo
  echo "Security:"
  echo "  1) WPA2-PSK"
  echo "  0) Open"
  read -r -p "Select security [1]: " SECURITY
  SECURITY="${SECURITY:-1}"
  [[ "${SECURITY}" == "0" || "${SECURITY}" == "1" ]] || die "Invalid security mode."

  if [[ "${SECURITY}" == "1" ]]; then
    PSK="$(ask "WPA2 passphrase" "halowmaui123")"
    [[ "${#PSK}" -ge 8 ]] || die "WPA2 passphrase must be at least 8 chars."
  else
    PSK=""
  fi

  if [[ "${ROLE}" == "ap" ]]; then
    CHANNEL="$(ask "S1G channel number" "9")"
    AP_IP="$(ask "AP static IP" "192.168.200.1")"
    AP_CIDR="$(ask "AP CIDR prefix" "24")"
    DHCP_START="$(ask "DHCP range start" "192.168.200.50")"
    DHCP_END="$(ask "DHCP range end" "192.168.200.150")"
  else
    STA_IP_MODE="$(ask "Client IP mode: dhcp or static" "dhcp")"
    if [[ "${STA_IP_MODE}" == "static" ]]; then
      STA_IP="$(ask "Client static IP/CIDR" "192.168.200.2/24")"
      STA_GW="$(ask "Client gateway" "192.168.200.1")"
      STA_DNS="$(ask "Client DNS" "192.168.200.1")"
    else
      STA_IP=""
      STA_GW=""
      STA_DNS=""
    fi
    CHANNEL=""
    AP_IP=""
    AP_CIDR=""
    DHCP_START=""
    DHCP_END=""
  fi

  cat > "${CONF}" <<EOF
ROLE="${ROLE}"
COUNTRY="${COUNTRY}"
SSID="${SSID}"
SECURITY="${SECURITY}"
PSK="${PSK}"
CHANNEL="${CHANNEL}"
AP_IP="${AP_IP}"
AP_CIDR="${AP_CIDR}"
DHCP_START="${DHCP_START}"
DHCP_END="${DHCP_END}"
STA_IP_MODE="${STA_IP_MODE:-}"
STA_IP="${STA_IP:-}"
STA_GW="${STA_GW:-}"
STA_DNS="${STA_DNS:-}"
EOF
  chmod 600 "${CONF}"
}

install_packages() {
  log "Installing packages"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    git build-essential bc bison flex libssl-dev make \
    raspberrypi-kernel-headers device-tree-compiler \
    iw wireless-regdb rfkill iproute2 iptables net-tools \
    hostapd dnsmasq python3

  systemctl disable --now hostapd 2>/dev/null || true
  systemctl disable --now dnsmasq 2>/dev/null || true
}

clone_repo() {
  log "Installing Newracom source"
  if [[ -d "${SRC_DIR}/.git" ]]; then
    git -C "${SRC_DIR}" pull --ff-only || true
  else
    rm -rf "${SRC_DIR}"
    git clone https://github.com/newracom/nrc7292_sw_pkg.git "${SRC_DIR}"
  fi
}

configure_boot() {
  log "Configuring boot overlays"

  [[ -f "${BOOT_CONFIG}" ]] || die "${BOOT_CONFIG} not found."
  cp -a "${BOOT_CONFIG}" "${BOOT_CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"

  sed -i \
    -e '/^dtparam=spi=/d' \
    -e '/^dtoverlay=newracom/d' \
    -e '/^#dtoverlay=newracom/d' \
    -e '/^dtoverlay=disable-wifi/d' \
    -e '/^dtoverlay=disable-bt/d' \
    -e '/^dtoverlay=disable-spidev/d' \
    -e '/^dtoverlay=pi3-disable-wifi/d' \
    -e '/^dtoverlay=pi3-disable-bt/d' \
    -e '/^dtoverlay=pi3-disable-spidev/d' \
    "${BOOT_CONFIG}"

  cat >> "${BOOT_CONFIG}" <<'EOF'

# NRC7292 HaLow host mode
dtparam=spi=on
dtoverlay=disable-bt
dtoverlay=disable-wifi
dtoverlay=disable-spidev
dtoverlay=newracom
EOF
}

build_overlay() {
  log "Building overlay"
  mkdir -p "${OVERLAY_DIR}"
  dtc -@ -I dts -O dtb \
    -o "${OVERLAY_DIR}/newracom.dtbo" \
    "${SRC_DIR}/dts/newracom_for_5.16_or_later.dts"
  chmod 755 "${OVERLAY_DIR}/newracom.dtbo"
}

build_driver() {
  log "Building nrc.ko for $(uname -r)"
  cd "${SRC_DIR}/package/src/nrc"
  make clean || true
  make
  install -D -m 0644 nrc.ko "/lib/modules/$(uname -r)/extra/nrc.ko"
  depmod -a
}

build_cli() {
  log "Building cli_app"
  cd "${SRC_DIR}/package/src/cli_app"
  make clean || true
  make
}

stage_runtime() {
  log "Staging runtime"
  rm -rf "${RUNTIME_DIR}"
  cp -a "${SRC_DIR}/package/evk/sw_pkg/nrc_pkg" "${RUNTIME_DIR}"

  mkdir -p "${RUNTIME_DIR}/sw/driver"
  cp -f "/lib/modules/$(uname -r)/extra/nrc.ko" "${RUNTIME_DIR}/sw/driver/nrc.ko"

  mkdir -p "${RUNTIME_DIR}/sw/firmware"
  cp -f "${SRC_DIR}/package/evk/binary/"* "${RUNTIME_DIR}/sw/firmware/" 2>/dev/null || true

  [[ -f "${RUNTIME_DIR}/sw/firmware/uni_s1g.bin" ]] || \
    cp -f "${RUNTIME_DIR}/sw/firmware/nrc7292_cspi.bin" "${RUNTIME_DIR}/sw/firmware/uni_s1g.bin"

  cp -f "${SRC_DIR}/package/src/cli_app/cli_app" "${RUNTIME_DIR}/script/cli_app"

  chmod -R a+rx "${RUNTIME_DIR}/script"
  chmod -R a+rx "${RUNTIME_DIR}/script/conf/etc" 2>/dev/null || true
  chmod +x "${RUNTIME_DIR}/script/cli_app"
  chmod +x "${RUNTIME_DIR}/sw/firmware/copy" 2>/dev/null || true

  mkdir -p /home/pi
  rm -rf "${LEGACY_RUNTIME}"
  ln -s "${RUNTIME_DIR}" "${LEGACY_RUNTIME}"
}

patch_runtime() {
  log "Patching runtime defaults"

  sed -i \
    -e 's/^spi_gpio_irq[[:space:]]*=.*/spi_gpio_irq = -1/' \
    -e 's/^spi_polling_interval[[:space:]]*=.*/spi_polling_interval = 5/' \
    -e "s/^fw_name[[:space:]]*=.*/fw_name           = 'uni_s1g.bin'/" \
    "${RUNTIME_DIR}/script/start.py"

  local conf_dir="${RUNTIME_DIR}/script/conf/${COUNTRY}"
  [[ -d "${conf_dir}" ]] || conf_dir="${RUNTIME_DIR}/script/conf/US"

  for f in "${conf_dir}"/*_halow_*.conf; do
    [[ -f "${f}" ]] || continue
    sed -i \
      -e "s/^ssid=.*/ssid=${SSID}/" \
      -e "s/^country_code=.*/country_code=${COUNTRY}/" \
      "${f}" || true

    if [[ "${SECURITY}" == "1" ]]; then
      sed -i \
        -e "s/^wpa_passphrase=.*/wpa_passphrase=${PSK}/" \
        -e "s/^#*wpa=.*/wpa=2/" \
        -e "s/^#*wpa_key_mgmt=.*/wpa_key_mgmt=WPA-PSK/" \
        -e "s/^#*rsn_pairwise=.*/rsn_pairwise=CCMP/" \
        "${f}" || true
    fi
  done

  local ip_cfg="${RUNTIME_DIR}/script/conf/etc/CONFIG_IP"
  if [[ -f "${ip_cfg}" && "${ROLE}" == "ap" ]]; then
    sed -i \
      -e "s/^AP_INTERFACE=.*/AP_INTERFACE=wlan0/" \
      -e "s/^AP_STATIC_IP=.*/AP_STATIC_IP=${AP_IP}/" \
      -e "s/^NET_MASK_NUM=.*/NET_MASK_NUM=${AP_CIDR}/" \
      "${ip_cfg}" || true
  fi

  cat > /etc/dnsmasq.d/halow.conf <<EOF
interface=wlan0
bind-interfaces
dhcp-range=${DHCP_START:-192.168.200.50},${DHCP_END:-192.168.200.150},255.255.255.0,12h
EOF
}

write_control_scripts() {
  log "Writing control scripts"

  cat > /usr/local/sbin/halow-start <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/halow.conf

cd /home/pi/nrc_pkg/script

pkill hostapd 2>/dev/null || true
systemctl stop dnsmasq 2>/dev/null || true
rmmod nrc 2>/dev/null || true
sleep 1

if [[ "${ROLE}" == "ap" ]]; then
  python3 start.py 1 "${SECURITY}" "${COUNTRY}" "${CHANNEL}"
  systemctl restart dnsmasq 2>/dev/null || true
else
  python3 start.py 0 "${SECURITY}" "${COUNTRY}"

  if [[ "${STA_IP_MODE}" == "static" ]]; then
    ip addr flush dev wlan0 || true
    ip addr add "${STA_IP}" dev wlan0
    ip route replace default via "${STA_GW}" dev wlan0 || true
    printf "nameserver %s\n" "${STA_DNS}" > /etc/resolv.conf
  else
    dhclient wlan0 2>/dev/null || true
  fi
fi
EOF

  cat > /usr/local/sbin/halow-stop <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
pkill hostapd 2>/dev/null || true
pkill dnsmasq 2>/dev/null || true
systemctl stop dnsmasq 2>/dev/null || true
ip link set wlan0 down 2>/dev/null || true
rmmod nrc 2>/dev/null || true
EOF

  cat > /usr/local/sbin/halow-status <<'EOF'
#!/usr/bin/env bash
set +e
echo "== config =="
cat /etc/halow.conf 2>/dev/null
echo
echo "== iw =="
iw dev 2>/dev/null
echo
echo "== links =="
ip -brief link
echo
echo "== nrc logs =="
dmesg -T | grep -iE 'nrc|s1g|firmware|board data|failed|error|ap-enabled|halow' | tail -100
echo
echo "== service =="
systemctl status halow --no-pager 2>/dev/null
EOF

  chmod +x /usr/local/sbin/halow-start /usr/local/sbin/halow-stop /usr/local/sbin/halow-status
}

write_service() {
  log "Creating systemd service"
  cat > "/etc/systemd/system/${SERVICE}" <<'EOF'
[Unit]
Description=NRC7292 HaLow
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/halow-start
ExecStop=/usr/local/sbin/halow-stop
TimeoutStartSec=120
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "${SERVICE}"
}

main() {
  require_root
  require_pi45
  prompt_config
  install_packages
  clone_repo
  configure_boot
  build_overlay
  build_driver
  build_cli
  stage_runtime
  patch_runtime
  write_control_scripts
  write_service

  cat <<EOF

[+] Install complete.

Reboot now:

  sudo reboot

After reboot:

  sudo systemctl start halow
  sudo halow-status

Role: ${ROLE}
SSID: ${SSID}
Country: ${COUNTRY}
Security: ${SECURITY}  0=open, 1=WPA2

EOF
}

main "$@"
