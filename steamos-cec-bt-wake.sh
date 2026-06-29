#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
MODE="install"
YES=0
EXPECTED_CONFIG_VERSION=2

CEC_DEVICE="${CEC_DEVICE:-/dev/cec0}"
CEC_DEST="com.steampowered.CecDaemon1"
CEC_INTERFACE="com.steampowered.CecDaemon1.CecDevice1"
CEC_OBJECT_PATH=""

CEC_SLEEP_SERVICE="/etc/systemd/system/cec-sleep.service"
CEC_WAKE_SERVICE="/etc/systemd/system/cec-wake.service"
BT_WAKE_SERVICE="/etc/systemd/system/bt-wakeup.service"
BT_WAKE_RULE="/etc/udev/rules.d/91-bluetooth-wakeup.rules"
BT_HELPER="/etc/steamos-cec-bt-wake/enable-bluetooth-wakeup"
CEC_HELPER="/etc/steamos-cec-bt-wake/cec-control"
MTK_RULE="/etc/udev/rules.d/99-btusb-mediatek.rules"
STATE_FILE="/etc/steamos-cec-bt-wake.conf"

DESKTOP_USER=""
DESKTOP_UID=""
CEC_PHYSICAL_ADDRESS_DETECTED=""
CEC_PHYSICAL_INTEGER_DETECTED=""
BT_PATH=""
BT_VENDOR="${BT_VENDOR:-}"
BT_PRODUCT="${BT_PRODUCT:-}"
BT_CLASS=""
BT_SUBCLASS=""
BT_PROTOCOL=""
BT_MANUFACTURER=""
BT_NAME=""

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
  CEC_PHYSICAL_ADDRESS=3.0.0.0
  DESKTOP_USER=username
  BT_VENDOR=0e8d
  BT_PRODUCT=0616
USAGE
}

parse_args() {
  local arg
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
}

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

configure_cec_device() {
  local cec_index
  [[ "$CEC_DEVICE" =~ ^/dev/cec([0-9]+)$ ]] || die "CEC_DEVICE must look like /dev/cec0."
  cec_index="${BASH_REMATCH[1]}"
  CEC_OBJECT_PATH="/com/steampowered/CecDaemon1/Devices/Cec${cec_index}"
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
  [[ -n "$user" ]] || user="$(
    find /run/user -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null |
      while read -r uid; do getent passwd "$uid" | cut -d: -f1; done |
      head -n1
  )"
  [[ -n "$user" ]] || die "Could not detect the desktop user. Re-run with DESKTOP_USER=yourname."
  printf '%s\n' "$user"
}

run_as_desktop_user() {
  [[ -n "${DESKTOP_USER:-}" && -n "${DESKTOP_UID:-}" ]] || die "Desktop user context is not initialized."
  runuser -u "$DESKTOP_USER" -- env \
    XDG_RUNTIME_DIR="/run/user/$DESKTOP_UID" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$DESKTOP_UID/bus" \
    "$@"
}

validate_physical_address_format() {
  local pa="$1"
  local normalized="${pa,,}"
  local a b c d
  IFS='.' read -r a b c d <<<"$normalized"
  [[ "$a" =~ ^[0-9a-f]$ && "$b" =~ ^[0-9a-f]$ && "$c" =~ ^[0-9a-f]$ && "$d" =~ ^[0-9a-f]$ ]]
}

validate_physical_address() {
  local pa="${1,,}"
  validate_physical_address_format "$pa" || return 1
  [[ "$pa" != "f.f.f.f" ]]
}

validate_physical_integer() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  (( value >= 0 && value <= 65535 )) || return 1
}

physical_to_integer() {
  local pa="${1,,}" a b c d
  validate_physical_address_format "$pa" || die "Invalid CEC physical address: $1"
  IFS='.' read -r a b c d <<<"$pa"
  printf '%d\n' "$(( (16#$a << 12) | (16#$b << 8) | (16#$c << 4) | 16#$d ))"
}

integer_to_physical() {
  local value="$1"
  validate_physical_integer "$value" || die "Invalid CEC physical address integer: $value"
  printf '%x.%x.%x.%x\n' \
    $(( (value >> 12) & 0xf )) \
    $(( (value >> 8) & 0xf )) \
    $(( (value >> 4) & 0xf )) \
    $(( value & 0xf ))
}

parse_cec_physical_address_from_output() {
  sed -nE \
    's/^[[:space:]]*Physical Address[[:space:]]*:[[:space:]]*(([0-9A-Fa-f]\.){3}[0-9A-Fa-f])[[:space:]]*$/\1/p'
}

get_cecd_physical_address_integer() {
  local output value
  output="$(run_as_desktop_user busctl --user get-property \
    "$CEC_DEST" "$CEC_OBJECT_PATH" "$CEC_INTERFACE" PhysicalAddress 2>/dev/null)" || return 1
  value="$(awk 'NR==1 {print $2}' <<<"$output")"
  validate_physical_integer "$value" || return 1
  printf '%s\n' "$value"
}

detect_cec_physical_address() {
  [[ -e "$CEC_DEVICE" ]] || die "$CEC_DEVICE does not exist. Confirm the CEC-capable adapter is connected."

  if [[ -n "${CEC_PHYSICAL_ADDRESS:-}" ]]; then
    validate_physical_address "$CEC_PHYSICAL_ADDRESS" || die "Invalid CEC_PHYSICAL_ADDRESS override: $CEC_PHYSICAL_ADDRESS"
    CEC_PHYSICAL_ADDRESS_DETECTED="${CEC_PHYSICAL_ADDRESS,,}"
    CEC_PHYSICAL_INTEGER_DETECTED="$(physical_to_integer "$CEC_PHYSICAL_ADDRESS_DETECTED")"
    return
  fi

  local live_integer output
  if command_exists busctl; then
    live_integer="$(get_cecd_physical_address_integer || true)"
    if [[ -n "$live_integer" ]]; then
      CEC_PHYSICAL_ADDRESS_DETECTED="$(integer_to_physical "$live_integer")"
      if validate_physical_address "$CEC_PHYSICAL_ADDRESS_DETECTED"; then
        CEC_PHYSICAL_INTEGER_DETECTED="$live_integer"
        return
      fi
      warn "cecd reported an unusable CEC physical address: $CEC_PHYSICAL_ADDRESS_DETECTED"
    fi
  fi

  command_exists cec-ctl || die "cec-ctl is required when cecd did not expose PhysicalAddress. Install v4l-utils first."

  output="$(cec-ctl -d "$CEC_DEVICE" --give-device-power-status 2>&1 || true)"
  CEC_PHYSICAL_ADDRESS_DETECTED="$(
    printf '%s\n' "$output" | parse_cec_physical_address_from_output | head -n1
  )"

  if [[ -z "$CEC_PHYSICAL_ADDRESS_DETECTED" ]]; then
    printf '%s\n' "$output" >&2
    die "Could not determine the labeled CEC physical address from cec-ctl output."
  fi

  validate_physical_address "$CEC_PHYSICAL_ADDRESS_DETECTED" || die "cec-ctl returned an invalid CEC physical address: $CEC_PHYSICAL_ADDRESS_DETECTED"
  CEC_PHYSICAL_INTEGER_DETECTED="$(physical_to_integer "$CEC_PHYSICAL_ADDRESS_DETECTED")"
}

list_all_usb_device_paths() {
  local dev base
  for dev in /sys/bus/usb/devices/*; do
    [[ -f "$dev/idVendor" && -f "$dev/idProduct" ]] || continue
    base="$(basename "$dev")"
    [[ "$base" == *:* ]] && continue
    printf '%s\n' "$dev"
  done
}

format_usb_candidate() {
  local dev="$1"
  local base vendor product manufacturer product_name class subclass protocol
  base="$(basename "$dev")"
  vendor="$(<"$dev/idVendor")"
  product="$(<"$dev/idProduct")"
  class="$(cat "$dev/bDeviceClass" 2>/dev/null || true)"
  subclass="$(cat "$dev/bDeviceSubClass" 2>/dev/null || true)"
  protocol="$(cat "$dev/bDeviceProtocol" 2>/dev/null || true)"
  manufacturer="$(cat "$dev/manufacturer" 2>/dev/null || true)"
  product_name="$(cat "$dev/product" 2>/dev/null || true)"
  printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$base" "$vendor" "$product" "$class" "$subclass" "$protocol" "$manufacturer" "$product_name"
}

list_bt_candidates() {
  local hci dev usb_parent
  declare -A seen=()

  for hci in /sys/class/bluetooth/hci*; do
    [[ -e "$hci" ]] || continue
    dev="$(readlink -f "$hci/device" 2>/dev/null || true)"
    [[ -n "$dev" ]] || continue
    usb_parent=""

    while [[ "$dev" != "/" ]]; do
      if [[ -f "$dev/idVendor" && -f "$dev/idProduct" ]]; then
        usb_parent="$dev"
        break
      fi
      dev="$(dirname "$dev")"
    done

    [[ -n "$usb_parent" ]] || continue
    [[ -n "${seen[$usb_parent]:-}" ]] && continue
    seen[$usb_parent]=1
    format_usb_candidate "$usb_parent"
  done
}

select_line_from_candidates() {
  local prompt="$1"
  shift
  local candidates=("$@")
  local line index

  ((${#candidates[@]} > 0)) || return 1

  if ((${#candidates[@]} == 1)); then
    printf '%s\n' "${candidates[0]}"
    return 0
  fi

  printf '%s\n' "$prompt" >&2
  for index in "${!candidates[@]}"; do
    IFS='|' read -r path vendor product class subclass protocol manufacturer name <<<"${candidates[$index]}"
    printf '  %d) %s  %s:%s  %s %s\n' "$((index + 1))" "$path" "$vendor" "$product" "$manufacturer" "$name" >&2
  done

  if (( YES )); then
    printf '%s\n' "${candidates[0]}"
    return 0
  fi

  read -r -p "Choose the Bluetooth device [1-${#candidates[@]}]: " index
  [[ "$index" =~ ^[0-9]+$ ]] && (( index >= 1 && index <= ${#candidates[@]} )) || die "Invalid selection."
  printf '%s\n' "${candidates[$((index - 1))]}"
}

find_usb_candidates_by_vidpid() {
  local vendor="${1,,}" product="${2,,}" dev device_vendor device_product
  for dev in /sys/bus/usb/devices/*; do
    [[ -f "$dev/idVendor" && -f "$dev/idProduct" ]] || continue
    [[ "$(basename "$dev")" == *:* ]] && continue
    device_vendor="$(<"$dev/idVendor")"
    device_product="$(<"$dev/idProduct")"
    [[ "${device_vendor,,}" == "$vendor" && "${device_product,,}" == "$product" ]] || continue
    format_usb_candidate "$dev"
  done
}

select_bt_device() {
  local selected_line
  local candidates=()

  if [[ -n "${BT_VENDOR:-}" && -n "${BT_PRODUCT:-}" ]]; then
    mapfile -t candidates < <(find_usb_candidates_by_vidpid "$BT_VENDOR" "$BT_PRODUCT")
    ((${#candidates[@]} > 0)) || die "No USB device matched BT_VENDOR=$BT_VENDOR BT_PRODUCT=$BT_PRODUCT."
    selected_line="$(select_line_from_candidates "Detected matching USB devices:" "${candidates[@]}")"
  else
    mapfile -t candidates < <(list_bt_candidates)
    ((${#candidates[@]} > 0)) || die "No Bluetooth HCI controller with a USB parent was detected."
    selected_line="$(select_line_from_candidates "Detected Bluetooth USB devices:" "${candidates[@]}")"
  fi

  IFS='|' read -r BT_PATH BT_VENDOR BT_PRODUCT BT_CLASS BT_SUBCLASS BT_PROTOCOL BT_MANUFACTURER BT_NAME <<<"$selected_line"
}

write_file() {
  local path="$1" mode="$2"
  install -D -m "$mode" /dev/stdin "$path"
}

install_cec_helper() {
  generate_cec_helper_content | write_file "$CEC_HELPER" 0755
}

generate_cec_helper_content() {
  cat <<EOF2
#!/usr/bin/env bash
set -euo pipefail

ACTION="\${1:?action required}"
ACTIVE_SOURCE="\${2:-}"
CEC_DEST="$CEC_DEST"
CEC_OBJECT_PATH="$CEC_OBJECT_PATH"
CEC_INTERFACE="$CEC_INTERFACE"

log()  { printf 'cec-control: %s\n' "\$*" >&2; }
warn() { printf 'cec-control: %s\n' "\$*" >&2; }

restart_cecd() {
  if ! systemctl --user restart cecd.service >/dev/null 2>&1; then
    warn "Failed to restart cecd.service"
  fi
}

wait_for_cecd_object() {
  local attempt
  for attempt in \$(seq 1 10); do
    if busctl --user get-property "\$CEC_DEST" "\$CEC_OBJECT_PATH" "\$CEC_INTERFACE" Active >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  warn "Timed out waiting for \$CEC_OBJECT_PATH on D-Bus"
  return 1
}

call_cec() {
  local method="\$1"
  shift
  local attempt output rc

  for attempt in 1 2 3; do
    if output="\$(gdbus call --session --dest "\$CEC_DEST" --object-path "\$CEC_OBJECT_PATH" --method "\$CEC_INTERFACE.\$method" "\$@" 2>&1)"; then
      [[ -n "\$output" ]] && log "\$method: \$output"
      return 0
    else
      rc=\$?
    fi

    if [[ -n "\$output" ]]; then
      warn "\$method attempt \$attempt failed: \$output"
    else
      warn "\$method attempt \$attempt failed"
    fi

    if grep -q 'TxError.Nack' <<<"\$output"; then
      sleep 1
      continue
    fi

    return "\$rc"
  done

  return 1
}

main() {
  restart_cecd
  wait_for_cecd_object || true

  case "\$ACTION" in
    standby)
      sleep 2
      call_cec Standby 0 || warn "Standby command failed"
      ;;
    wake)
      if [[ -z "\$ACTIVE_SOURCE" ]]; then
        warn "Wake requested without an active-source argument"
        exit 0
      fi
      sleep 3
      call_cec Wake || warn "Wake command failed"
      sleep 2
      call_cec SetActiveSource "\$ACTIVE_SOURCE" || warn "SetActiveSource command failed"
      ;;
    *)
      warn "Unknown action: \$ACTION"
      exit 2
      ;;
  esac
}

if [[ "\${BASH_SOURCE[0]:-\$0}" == "\$0" ]]; then
  main "\$@"
fi
EOF2
}

install_cec() {
  local desktop_user="$1" desktop_uid="$2" physical="$3" physical_int="$4"

  install_cec_helper

  log "Writing CEC sleep and wake services"
  cat <<EOF2 | write_file "$CEC_SLEEP_SERVICE" 0644
[Unit]
Description=CEC TV Standby on Sleep
Before=sleep.target
StopWhenUnneeded=yes

[Service]
Type=oneshot
User=$desktop_user
Environment=XDG_RUNTIME_DIR=/run/user/$desktop_uid
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$desktop_uid/bus
ExecStart=$CEC_HELPER standby

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
Environment=XDG_RUNTIME_DIR=/run/user/$desktop_uid
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$desktop_uid/bus
ExecStart=$CEC_HELPER wake $physical_int

[Install]
WantedBy=suspend.target
EOF2

  cat <<EOF2 | write_file "$STATE_FILE" 0644
CONFIG_VERSION=$EXPECTED_CONFIG_VERSION
DESKTOP_USER=$desktop_user
DESKTOP_UID=$desktop_uid
CEC_DEVICE=$CEC_DEVICE
CEC_OBJECT_PATH=$CEC_OBJECT_PATH
CEC_PHYSICAL_ADDRESS=$physical
CEC_PHYSICAL_INTEGER=$physical_int
BT_VENDOR=${BT_VENDOR:-}
BT_PRODUCT=${BT_PRODUCT:-}
EOF2
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
}

load_state_file() {
  [[ -r "$STATE_FILE" ]] || die "State file not found: $STATE_FILE"
  # shellcheck disable=SC1090
  source "$STATE_FILE"
}

get_wake_service_argument() {
  [[ -r "$CEC_WAKE_SERVICE" ]] || return 1
  sed -nE "s|^ExecStart=${CEC_HELPER//\//\\/}[[:space:]]+wake[[:space:]]+([0-9]+)[[:space:]]*$|\1|p" "$CEC_WAKE_SERVICE" | head -n1
}

verify() {
  local failures=0
  local live_integer live_physical active_state wake_argument
  local matched=0 dev wake

  load_state_file
  configure_cec_device

  if [[ -z "${DESKTOP_USER:-}" || -z "${DESKTOP_UID:-}" ]]; then
    printf 'FAIL Missing desktop user context in %s\n' "$STATE_FILE"
    return 1
  fi

  printf '\nCEC\n---\n'

  if [[ "${CONFIG_VERSION:-0}" != "$EXPECTED_CONFIG_VERSION" ]]; then
    printf 'WARN Config version is %s, expected %s\n' "${CONFIG_VERSION:-unknown}" "$EXPECTED_CONFIG_VERSION"
  fi

  if ! validate_physical_integer "${CEC_PHYSICAL_INTEGER:-}"; then
    if [[ "${CEC_PHYSICAL_INTEGER:-}" =~ ^[0-9]+$ ]] && (( CEC_PHYSICAL_INTEGER > 65535 )); then
      printf 'FAIL This installation was created by a version with the old CEC address conversion bug. Re-run --install to repair it.\n'
    else
      printf 'FAIL Invalid stored CEC physical address integer: %s\n' "${CEC_PHYSICAL_INTEGER:-missing}"
    fi
    failures=$((failures + 1))
  fi

  if validate_physical_address "${CEC_PHYSICAL_ADDRESS:-}"; then
    printf 'OK   Stored CEC physical address: %s\n' "$CEC_PHYSICAL_ADDRESS"
  else
    printf 'FAIL Invalid stored CEC physical address: %s\n' "${CEC_PHYSICAL_ADDRESS:-missing}"
    failures=$((failures + 1))
  fi

  if [[ -e "${CEC_DEVICE:-/dev/cec0}" ]]; then
    printf 'OK   CEC device exists: %s\n' "${CEC_DEVICE:-/dev/cec0}"
  else
    printf 'FAIL CEC device missing: %s\n' "${CEC_DEVICE:-/dev/cec0}"
    failures=$((failures + 1))
  fi

  if [[ -r "$CEC_HELPER" ]]; then
    printf 'OK   CEC helper exists: %s\n' "$CEC_HELPER"
  else
    printf 'FAIL CEC helper missing: %s\n' "$CEC_HELPER"
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

  if run_as_desktop_user systemctl --user is-active --quiet cecd.service 2>/dev/null; then
    printf 'OK   cecd.service active in the user manager\n'
  else
    printf 'FAIL cecd.service is not active in the user manager\n'
    failures=$((failures + 1))
  fi

  if run_as_desktop_user busctl --user get-property "$CEC_DEST" "$CEC_OBJECT_PATH" "$CEC_INTERFACE" Active >/dev/null 2>&1; then
    printf 'OK   %s is reachable on the user session bus\n' "$CEC_DEST"
  else
    printf 'FAIL Could not reach the CEC D-Bus object on the user session bus\n'
    failures=$((failures + 1))
  fi

  active_state="$(
    {
      run_as_desktop_user busctl --user get-property "$CEC_DEST" "$CEC_OBJECT_PATH" "$CEC_INTERFACE" Active 2>/dev/null |
        awk 'NR==1 {print $2}'
    } || true
  )"
  if [[ "$active_state" == "true" ]]; then
    printf 'OK   cecd Active property is true\n'
  elif [[ -n "$active_state" ]]; then
    printf 'WARN cecd Active property is %s\n' "$active_state"
  else
    printf 'FAIL Could not read cecd Active property for %s\n' "$CEC_OBJECT_PATH"
    failures=$((failures + 1))
  fi

  live_integer="$(get_cecd_physical_address_integer || true)"
  if [[ -n "$live_integer" ]]; then
    live_physical="$(integer_to_physical "$live_integer")"
    if validate_physical_address "$live_physical"; then
      printf 'OK   cecd PhysicalAddress: %s (%s)\n' "$live_physical" "$live_integer"
    else
      printf 'FAIL cecd PhysicalAddress is unusable: %s (%s)\n' "$live_physical" "$live_integer"
      failures=$((failures + 1))
    fi
  else
    printf 'FAIL Could not read cecd PhysicalAddress for %s\n' "$CEC_OBJECT_PATH"
    failures=$((failures + 1))
  fi

  wake_argument="$(get_wake_service_argument || true)"
  if [[ -n "$wake_argument" ]]; then
    printf 'OK   cec-wake.service SetActiveSource argument: %s\n' "$wake_argument"
  else
    printf 'FAIL Could not parse the wake helper argument from %s\n' "$CEC_WAKE_SERVICE"
    failures=$((failures + 1))
  fi

  if [[ -n "${CEC_PHYSICAL_INTEGER:-}" && -n "$live_integer" && "$CEC_PHYSICAL_INTEGER" == "$live_integer" ]]; then
    printf 'OK   Stored CEC physical integer matches cecd\n'
  else
    printf 'FAIL Stored CEC physical integer (%s) does not match cecd (%s)\n' "${CEC_PHYSICAL_INTEGER:-missing}" "${live_integer:-missing}"
    failures=$((failures + 1))
  fi

  if [[ -n "${CEC_PHYSICAL_INTEGER:-}" && -n "$wake_argument" && "$CEC_PHYSICAL_INTEGER" == "$wake_argument" ]]; then
    printf 'OK   Wake service argument matches the stored CEC physical integer\n'
  else
    printf 'FAIL Wake service argument (%s) does not match the stored CEC physical integer (%s)\n' "${wake_argument:-missing}" "${CEC_PHYSICAL_INTEGER:-missing}"
    failures=$((failures + 1))
  fi

  printf '\nBluetooth wake\n--------------\n'
  if systemctl is-enabled --quiet bt-wakeup.service 2>/dev/null; then
    printf 'OK   bt-wakeup.service enabled\n'
  else
    printf 'FAIL bt-wakeup.service not enabled\n'
    failures=$((failures + 1))
  fi

  if [[ -r "$BT_WAKE_RULE" ]]; then
    printf 'OK   Bluetooth udev rule exists: %s\n' "$BT_WAKE_RULE"
  else
    printf 'FAIL Bluetooth udev rule missing: %s\n' "$BT_WAKE_RULE"
    failures=$((failures + 1))
  fi

  if [[ -n "${BT_VENDOR:-}" && -n "${BT_PRODUCT:-}" ]]; then
    for dev in /sys/bus/usb/devices/*; do
      [[ -f "$dev/idVendor" && -f "$dev/idProduct" ]] || continue
      [[ "$(basename "$dev")" == *:* ]] && continue
      [[ "$(<"$dev/idVendor")" == "$BT_VENDOR" && "$(<"$dev/idProduct")" == "$BT_PRODUCT" ]] || continue
      matched=1
      wake="$(cat "$dev/power/wakeup" 2>/dev/null || echo unavailable)"
      if [[ "$wake" == "enabled" ]]; then
        printf 'OK   %s (%s:%s) wakeup enabled\n' "$(basename "$dev")" "$BT_VENDOR" "$BT_PRODUCT"
      else
        printf 'FAIL %s (%s:%s) wakeup is %s\n' "$(basename "$dev")" "$BT_VENDOR" "$BT_PRODUCT" "$wake"
        failures=$((failures + 1))
      fi
    done
    (( matched )) || {
      printf 'FAIL Bluetooth device %s:%s not found\n' "$BT_VENDOR" "$BT_PRODUCT"
      failures=$((failures + 1))
    }
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
    "$BT_WAKE_RULE" "$BT_HELPER" "$CEC_HELPER" "$MTK_RULE" "$STATE_FILE"
  systemctl daemon-reload
  udevadm control --reload-rules 2>/dev/null || true
  log "Removed CEC and Bluetooth wake configuration installed by this script"
}

main() {
  parse_args "$@"
  require_root
  configure_cec_device

  case "$MODE" in
    uninstall)
      uninstall_all
      exit 0
      ;;
    verify)
      load_state_file
      verify
      exit $?
      ;;
  esac

  command_exists systemctl || die "systemd is required."
  command_exists gdbus || die "gdbus is required."
  command_exists udevadm || die "udevadm is required."
  command_exists busctl || die "busctl is required."
  command_exists runuser || die "runuser is required."

  DESKTOP_USER="$(detect_desktop_user)"
  DESKTOP_UID="$(id -u "$DESKTOP_USER")"
  detect_cec_physical_address
  select_bt_device

  cat <<SUMMARY

Detected configuration:
  Desktop user:       $DESKTOP_USER (UID $DESKTOP_UID)
  CEC device:         $CEC_DEVICE
  CEC D-Bus path:     $CEC_OBJECT_PATH
  Physical address:   $CEC_PHYSICAL_ADDRESS_DETECTED
  Active-source value:$CEC_PHYSICAL_INTEGER_DETECTED
  Bluetooth USB:      $BT_PATH ($BT_VENDOR:$BT_PRODUCT)
  Bluetooth name:     ${BT_MANUFACTURER:-} ${BT_NAME:-}
SUMMARY

  confirm "Install this configuration?" || die "Cancelled."

  install_cec "$DESKTOP_USER" "$DESKTOP_UID" "$CEC_PHYSICAL_ADDRESS_DETECTED" "$CEC_PHYSICAL_INTEGER_DETECTED"
  install_bt

  log "Reloading systemd and udev rules"
  systemctl daemon-reload
  udevadm control --reload-rules
  udevadm trigger --subsystem-match=usb --action=add || true

  systemctl enable cec-sleep.service cec-wake.service bt-wakeup.service
  systemctl restart bt-wakeup.service

  log "Installation complete"
  if ! verify; then
    warn "Installation files were written, but verification failed."
    exit 1
  fi

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

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  main "$@"
fi
