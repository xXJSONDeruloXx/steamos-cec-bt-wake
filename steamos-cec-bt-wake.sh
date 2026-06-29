#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
MODE="install"
YES=0
CEC_DEVICE="${CEC_DEVICE:-/dev/cec0}"
CEC_OBJECT_PATH="/com/steampowered/CecDaemon1/Devices/Cec0"
CEC_DEST="com.steampowered.CecDaemon1"
CEC_INTERFACE="com.steampowered.CecDaemon1.CecDevice1"

CEC_SLEEP_SERVICE="/etc/systemd/system/cec-sleep.service"
CEC_WAKE_SERVICE="/etc/systemd/system/cec-wake.service"
BT_WAKE_SERVICE="/etc/systemd/system/bt-wakeup.service"
BT_WAKE_RULE="/etc/udev/rules.d/91-bluetooth-wakeup.rules"
BT_HELPER="/etc/steamos-cec-bt-wake/enable-bluetooth-wakeup"
MTK_RULE="/etc/udev/rules.d/99-btusb-mediatek.rules"
STATE_FILE="/etc/steamos-cec-bt-wake.conf"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<USAGE
Usage: sudo ./$SCRIPT_NAME [OPTION]

Options:
  --install      Install or refresh CEC and Bluetooth wake configuration (default)
  --verify       Check the current configuration and hardware state
  --uninstall    Remove files and services installed by this script
  --yes, -y      Accept detected devices without confirmation
  --help, -h     Show this help

Environment overrides:
  CEC_DEVICE=/dev/cec0
  DESKTOP_USER=username
  BT_VENDOR=0e8d
  BT_PRODUCT=0616
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --install) MODE="install" ;;
    --verify) MODE="verify" ;;
    --uninstall) MODE="uninstall" ;;
    --yes|-y) YES=1 ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown option: $arg" ;;
  esac
done

require_root() {
  [[ $EUID -eq 0 ]] || die "Run this script with sudo."
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

confirm() {
  local prompt="$1"
  (( YES )) && return 0
  read -r -p "$prompt [Y/n] " reply
  [[ -z "$reply" || "$reply" =~ ^[Yy]$ ]]
}

detect_desktop_user() {
  if [[ -n "${DESKTOP_USER:-}" ]]; then
    id "$DESKTOP_USER" >/dev/null 2>&1 || die "DESKTOP_USER '$DESKTOP_USER' does not exist."
    printf '%s\n' "$DESKTOP_USER"
    return
  fi

  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    printf '%s\n' "$SUDO_USER"
    return
  fi

  local user
  user="$(loginctl list-sessions --no-legend 2>/dev/null | awk '$3 != "root" {print $3; exit}')"
  [[ -n "$user" ]] || user="$(find /run/user -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | while read -r uid; do getent passwd "$uid" | cut -d: -f1; done | head -n1)"
  [[ -n "$user" ]] || die "Could not detect the desktop user. Re-run with DESKTOP_USER=yourname."
  printf '%s\n' "$user"
}

physical_to_integer() {
  local pa="$1" a b c d
  IFS='.' read -r a b c d <<<"$pa"
  [[ "$a" =~ ^[0-9A-Fa-f]$ && "$b" =~ ^[0-9A-Fa-f]$ && "$c" =~ ^[0-9A-Fa-f]$ && "$d" =~ ^[0-9A-Fa-f]$ ]] \
    || die "Invalid CEC physical address: $pa"
  printf '%d\n' "$(( (16#$a << 16) | (16#$b << 12) | (16#$c << 8) | (16#$d << 4) ))"
}

detect_cec_physical_address() {
  [[ -e "$CEC_DEVICE" ]] || die "$CEC_DEVICE does not exist. Confirm the CEC-capable adapter is connected."
  command_exists cec-ctl || die "cec-ctl is required but was not found. Install v4l-utils first."

  local output pa
  output="$(cec-ctl -d "$CEC_DEVICE" --give-device-power-status 2>&1 || true)"
  pa="$(printf '%s\n' "$output" | sed -nE 's/.*[Pp]hysical [Aa]ddress[^0-9A-Fa-f]*([0-9A-Fa-f]\.[0-9A-Fa-f]\.[0-9A-Fa-f]\.[0-9A-Fa-f]).*/\1/p' | head -n1)"

  if [[ -z "$pa" ]]; then
    pa="$(printf '%s\n' "$output" | grep -Eo '([0-9A-Fa-f]\.){3}[0-9A-Fa-f]' | head -n1 || true)"
  fi

  [[ -n "$pa" ]] || {
    printf '%s\n' "$output" >&2
    die "Could not determine the CEC physical address from cec-ctl output."
  }
  printf '%s\n' "$pa"
}

list_bt_candidates() {
  local dev base vendor product manufacturer product_name class subclass protocol
  for dev in /sys/bus/usb/devices/*; do
    [[ -f "$dev/idVendor" && -f "$dev/idProduct" ]] || continue
    base="$(basename "$dev")"
    [[ "$base" == *:* ]] && continue

    vendor="$(<"$dev/idVendor")"
    product="$(<"$dev/idProduct")"
    class="$(cat "$dev/bDeviceClass" 2>/dev/null || true)"
    subclass="$(cat "$dev/bDeviceSubClass" 2>/dev/null || true)"
    protocol="$(cat "$dev/bDeviceProtocol" 2>/dev/null || true)"
    manufacturer="$(cat "$dev/manufacturer" 2>/dev/null || true)"
    product_name="$(cat "$dev/product" 2>/dev/null || true)"

    if grep -qi bluetooth "$dev/product" 2>/dev/null \
       || find "$dev" -maxdepth 3 -type d -name bluetooth -print -quit 2>/dev/null | grep -q .; then
      printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$base" "$vendor" "$product" "$class" "$subclass" "$protocol" "$manufacturer" "$product_name"
    fi
  done
}

select_bt_device() {
  local candidates=() line index
  mapfile -t candidates < <(list_bt_candidates)

  if [[ -n "${BT_VENDOR:-}" && -n "${BT_PRODUCT:-}" ]]; then
    for line in "${candidates[@]}"; do
      IFS='|' read -r BT_PATH vendor product BT_CLASS BT_SUBCLASS BT_PROTOCOL BT_MANUFACTURER BT_NAME <<<"$line"
      if [[ "$vendor" == "$BT_VENDOR" && "$product" == "$BT_PRODUCT" ]]; then
        return 0
      fi
    done
    die "No Bluetooth USB device matched BT_VENDOR=$BT_VENDOR BT_PRODUCT=$BT_PRODUCT."
  fi

  ((${#candidates[@]} > 0)) || die "No USB Bluetooth controller was detected."

  if ((${#candidates[@]} == 1)); then
    line="${candidates[0]}"
  else
    printf 'Detected Bluetooth USB devices:\n' >&2
    for index in "${!candidates[@]}"; do
      IFS='|' read -r path vendor product class subclass protocol manufacturer name <<<"${candidates[$index]}"
      printf '  %d) %s  %s:%s  %s %s\n' "$((index + 1))" "$path" "$vendor" "$product" "$manufacturer" "$name" >&2
    done
    read -r -p "Choose the Bluetooth device [1-${#candidates[@]}]: " index
    [[ "$index" =~ ^[0-9]+$ ]] && (( index >= 1 && index <= ${#candidates[@]} )) || die "Invalid selection."
    line="${candidates[$((index - 1))]}"
  fi

  IFS='|' read -r BT_PATH BT_VENDOR BT_PRODUCT BT_CLASS BT_SUBCLASS BT_PROTOCOL BT_MANUFACTURER BT_NAME <<<"$line"
}

write_file() {
  local path="$1" mode="$2"
  install -D -m "$mode" /dev/stdin "$path"
}

install_cec() {
  local desktop_user="$1" desktop_uid="$2" physical="$3" physical_int="$4"

  log "Writing CEC sleep and wake services"
  cat <<EOF2 | write_file "$CEC_SLEEP_SERVICE" 0644
[Unit]
Description=CEC TV Standby on Sleep
Before=sleep.target
StopWhenUnneeded=yes

[Service]
Type=oneshot
User=$desktop_user
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$desktop_uid/bus
ExecStart=/usr/bin/gdbus call --session --dest $CEC_DEST --object-path $CEC_OBJECT_PATH --method $CEC_INTERFACE.Standby 0

[Install]
WantedBy=sleep.target
EOF2

  cat <<EOF2 | write_file "$CEC_WAKE_SERVICE" 0644
[Unit]
Description=CEC TV Wake on Resume
After=suspend.target

[Service]
Type=oneshot
User=$desktop_user
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$desktop_uid/bus
ExecStart=/usr/bin/gdbus call --session --dest $CEC_DEST --object-path $CEC_OBJECT_PATH --method $CEC_INTERFACE.Wake
ExecStart=/usr/bin/gdbus call --session --dest $CEC_DEST --object-path $CEC_OBJECT_PATH --method $CEC_INTERFACE.SetActiveSource $physical_int

[Install]
WantedBy=suspend.target
EOF2

  cat > "$STATE_FILE" <<EOF2
DESKTOP_USER=$desktop_user
DESKTOP_UID=$desktop_uid
CEC_DEVICE=$CEC_DEVICE
CEC_PHYSICAL_ADDRESS=$physical
CEC_PHYSICAL_INTEGER=$physical_int
BT_VENDOR=${BT_VENDOR:-}
BT_PRODUCT=${BT_PRODUCT:-}
EOF2
  chmod 0644 "$STATE_FILE"
}

install_bt() {
  log "Configuring Bluetooth wake for $BT_VENDOR:$BT_PRODUCT ($BT_MANUFACTURER $BT_NAME)"

  cat <<'EOF2' | write_file "$BT_HELPER" 0755
#!/usr/bin/env bash
set -euo pipefail
vendor="${1:?vendor ID required}"
product="${2:?product ID required}"
found=0
for dev in /sys/bus/usb/devices/*; do
  [[ -f "$dev/idVendor" && -f "$dev/idProduct" && -f "$dev/power/wakeup" ]] || continue
  [[ "$(<"$dev/idVendor")" == "$vendor" && "$(<"$dev/idProduct")" == "$product" ]] || continue
  echo enabled > "$dev/power/wakeup"
  printf 'Enabled wakeup for %s (%s:%s)\n' "$(basename "$dev")" "$vendor" "$product"
  found=1
done
(( found == 1 )) || { echo "Bluetooth USB device $vendor:$product not found" >&2; exit 1; }
EOF2

  cat <<EOF2 | write_file "$BT_WAKE_RULE" 0644
ACTION=="add|bind", SUBSYSTEM=="usb", ATTR{idVendor}=="$BT_VENDOR", ATTR{idProduct}=="$BT_PRODUCT", TEST=="power/wakeup", ATTR{power/wakeup}="enabled"
EOF2

  cat <<EOF2 | write_file "$BT_WAKE_SERVICE" 0644
[Unit]
Description=Enable Bluetooth USB wakeup
After=bluetooth.target

[Service]
Type=oneshot
ExecStart=$BT_HELPER $BT_VENDOR $BT_PRODUCT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF2

  if [[ "$BT_VENDOR:$BT_PRODUCT" == "0e8d:0616" ]]; then
    log "Installing the MediaTek MT7921 btusb workaround"
    cat <<'EOF2' | write_file "$MTK_RULE" 0644
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="0e8d", ATTR{idProduct}=="0616", RUN+="/bin/sh -c 'echo 0e8d 0616 > /sys/bus/usb/drivers/btusb/new_id'"
EOF2
  else
    rm -f "$MTK_RULE"
  fi

  sed -i "/^BT_VENDOR=/c\BT_VENDOR=$BT_VENDOR" "$STATE_FILE"
  sed -i "/^BT_PRODUCT=/c\BT_PRODUCT=$BT_PRODUCT" "$STATE_FILE"
}

verify() {
  local failures=0 state_vendor="${BT_VENDOR:-}" state_product="${BT_PRODUCT:-}"
  [[ -r "$STATE_FILE" ]] && source "$STATE_FILE"
  state_vendor="${BT_VENDOR:-$state_vendor}"
  state_product="${BT_PRODUCT:-$state_product}"

  printf '\nCEC\n---\n'
  if [[ -e "${CEC_DEVICE:-/dev/cec0}" ]]; then
    printf 'OK   CEC device exists: %s\n' "${CEC_DEVICE:-/dev/cec0}"
  else
    printf 'FAIL CEC device missing: %s\n' "${CEC_DEVICE:-/dev/cec0}"
    failures=$((failures + 1))
  fi

  for svc in cec-sleep.service cec-wake.service; do
    if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
      printf 'OK   %s enabled\n' "$svc"
    else
      printf 'FAIL %s not enabled\n' "$svc"
      failures=$((failures + 1))
    fi
  done

  if command_exists busctl && systemctl is-active --quiet cecd.service 2>/dev/null; then
    printf 'OK   cecd.service active\n'
  else
    printf 'WARN cecd.service was not confirmed active\n'
  fi

  printf '\nBluetooth wake\n--------------\n'
  if systemctl is-enabled --quiet bt-wakeup.service 2>/dev/null; then
    printf 'OK   bt-wakeup.service enabled\n'
  else
    printf 'FAIL bt-wakeup.service not enabled\n'
    failures=$((failures + 1))
  fi

  if [[ -n "$state_vendor" && -n "$state_product" ]]; then
    local matched=0 dev wake
    for dev in /sys/bus/usb/devices/*; do
      [[ -f "$dev/idVendor" && -f "$dev/idProduct" ]] || continue
      [[ "$(<"$dev/idVendor")" == "$state_vendor" && "$(<"$dev/idProduct")" == "$state_product" ]] || continue
      matched=1
      wake="$(cat "$dev/power/wakeup" 2>/dev/null || echo unavailable)"
      if [[ "$wake" == "enabled" ]]; then
        printf 'OK   %s (%s:%s) wakeup enabled\n' "$(basename "$dev")" "$state_vendor" "$state_product"
      else
        printf 'FAIL %s (%s:%s) wakeup is %s\n' "$(basename "$dev")" "$state_vendor" "$state_product" "$wake"
        failures=$((failures + 1))
      fi
    done
    (( matched )) || { printf 'FAIL Bluetooth device %s:%s not found\n' "$state_vendor" "$state_product"; failures=$((failures + 1)); }
  else
    printf 'WARN No saved Bluetooth vendor/product IDs found\n'
  fi

  printf '\n'
  if (( failures == 0 )); then
    printf 'Verification passed.\n'
  else
    printf 'Verification found %d problem(s).\n' "$failures"
    return 1
  fi
}

uninstall_all() {
  log "Disabling installed services"
  systemctl disable --now cec-sleep.service cec-wake.service bt-wakeup.service 2>/dev/null || true
  rm -f "$CEC_SLEEP_SERVICE" "$CEC_WAKE_SERVICE" "$BT_WAKE_SERVICE" \
        "$BT_WAKE_RULE" "$BT_HELPER" "$MTK_RULE" "$STATE_FILE"
  systemctl daemon-reload
  udevadm control --reload-rules 2>/dev/null || true
  log "Removed CEC and Bluetooth wake configuration installed by this script"
}

main() {
  require_root

  case "$MODE" in
    uninstall)
      uninstall_all
      exit 0
      ;;
    verify)
      verify
      exit $?
      ;;
  esac

  command_exists systemctl || die "systemd is required."
  command_exists gdbus || die "gdbus is required."
  command_exists udevadm || die "udevadm is required."

  local desktop_user desktop_uid physical physical_int
  desktop_user="$(detect_desktop_user)"
  desktop_uid="$(id -u "$desktop_user")"
  physical="$(detect_cec_physical_address)"
  physical_int="$(physical_to_integer "$physical")"
  select_bt_device

  cat <<SUMMARY

Detected configuration:
  Desktop user:       $desktop_user (UID $desktop_uid)
  CEC device:         $CEC_DEVICE
  Physical address:   $physical
  Active-source value:$physical_int
  Bluetooth USB:      $BT_PATH ($BT_VENDOR:$BT_PRODUCT)
  Bluetooth name:     ${BT_MANUFACTURER:-} ${BT_NAME:-}
SUMMARY

  confirm "Install this configuration?" || die "Cancelled."

  install_cec "$desktop_user" "$desktop_uid" "$physical" "$physical_int"
  install_bt

  log "Reloading systemd and udev rules"
  systemctl daemon-reload
  udevadm control --reload-rules
  udevadm trigger --subsystem-match=usb --action=add || true

  systemctl enable cec-sleep.service cec-wake.service bt-wakeup.service
  systemctl restart bt-wakeup.service

  log "Installation complete"
  verify || true

  cat <<'NEXT'

Test from Game Mode after a full reboot:
  1. Put the PC to sleep and confirm the TV enters standby.
  2. Wake with a Bluetooth controller, keyboard, or mouse.
  3. Confirm the TV powers on and switches to the correct HDMI input.

Useful commands:
  sudo ./steamos-cec-bt-wake.sh --verify
  sudo ./steamos-cec-bt-wake.sh --uninstall
NEXT
}

main
