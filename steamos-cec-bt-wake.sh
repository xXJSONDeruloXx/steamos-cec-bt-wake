#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
MODE="install"
YES=0
EXPECTED_CONFIG_VERSION=3

CEC_DEVICE="${CEC_DEVICE:-/dev/cec0}"
CEC_DEST="com.steampowered.CecDaemon1"
CEC_INTERFACE="com.steampowered.CecDaemon1.CecDevice1"
CEC_OBJECT_PATH=""

VAR_LIB_DIR="/var/lib/steamos-cec-bt-wake"
LEGACY_HELPER_DIR="/etc/steamos-cec-bt-wake"
STATE_FILE="$VAR_LIB_DIR/state.conf"
LEGACY_STATE_FILE="/etc/steamos-cec-bt-wake.conf"
CEC_SLEEP_SERVICE="/etc/systemd/system/cec-sleep.service"
CEC_WAKE_SERVICE="/etc/systemd/system/cec-wake.service"
BT_WAKE_SERVICE="/etc/systemd/system/bt-wakeup.service"
BT_WAKE_RULE="/etc/udev/rules.d/91-bluetooth-wakeup.rules"
CEC_HELPER="$VAR_LIB_DIR/cec-control"
BT_HELPER="$VAR_LIB_DIR/enable-bluetooth-wakeup"
LEGACY_CEC_HELPER="$LEGACY_HELPER_DIR/cec-control"
LEGACY_BT_HELPER="$LEGACY_HELPER_DIR/enable-bluetooth-wakeup"
MTK_RULE="/etc/udev/rules.d/99-btusb-mediatek.rules"
ATOMIC_UPDATE_KEEP_DIR="/etc/atomic-update.conf.d"
ATOMIC_UPDATE_KEEP_FILE="$ATOMIC_UPDATE_KEEP_DIR/steamos-cec-bt-wake.conf"

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
STATE_SOURCE=""

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
  local index

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

ensure_var_layout() {
  install -d -m 0755 "$VAR_LIB_DIR"
}

migrate_legacy_layout() {
  local migrated=0
  ensure_var_layout

  if [[ -r "$LEGACY_STATE_FILE" && ! -e "$STATE_FILE" ]]; then
    install -m 0644 "$LEGACY_STATE_FILE" "$STATE_FILE"
    migrated=1
  fi

  if [[ -r "$LEGACY_CEC_HELPER" && ! -e "$CEC_HELPER" ]]; then
    install -m 0755 "$LEGACY_CEC_HELPER" "$CEC_HELPER"
    migrated=1
  fi

  if [[ -r "$LEGACY_BT_HELPER" && ! -e "$BT_HELPER" ]]; then
    install -m 0755 "$LEGACY_BT_HELPER" "$BT_HELPER"
    migrated=1
  fi

  if (( migrated == 1 )); then
    log "Migrated legacy /etc install data into $VAR_LIB_DIR"
  fi
}

atomic_keep_paths() {
  cat <<EOF2
/etc/steamos-cec-bt-wake.conf
/etc/steamos-cec-bt-wake/**
/etc/systemd/system/cec-sleep.service
/etc/systemd/system/cec-wake.service
/etc/systemd/system/bt-wakeup.service
/etc/udev/rules.d/91-bluetooth-wakeup.rules
/etc/udev/rules.d/99-btusb-mediatek.rules
/etc/atomic-update.conf.d/steamos-cec-bt-wake.conf
EOF2
}

write_atomic_update_keep_list() {
  install -d -m 0755 "$ATOMIC_UPDATE_KEEP_DIR"
  {
    printf '# Preserve steamos-cec-bt-wake files across SteamOS atomic updates.\n'
    atomic_keep_paths
  } | write_file "$ATOMIC_UPDATE_KEEP_FILE" 0644
}

remove_atomic_update_keep_list() {
  rm -f "$ATOMIC_UPDATE_KEEP_FILE"
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

  ensure_var_layout
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
  ensure_var_layout
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

read_state_file() {
  local path="$1"
  [[ -r "$path" ]] || return 1
  # shellcheck disable=SC1090
  source "$path"
  STATE_SOURCE="$path"
}

load_any_state_file() {
  STATE_SOURCE=""
  if read_state_file "$STATE_FILE"; then
    return 0
  fi
  if read_state_file "$LEGACY_STATE_FILE"; then
    return 0
  fi
  return 1
}

get_service_execstart() {
  local service_path="$1"
  [[ -r "$service_path" ]] || return 1
  sed -n 's/^ExecStart=//p' "$service_path" | head -n1
}

get_service_user() {
  local service_path="$1"
  [[ -r "$service_path" ]] || return 1
  sed -n 's/^User=//p' "$service_path" | head -n1
}

get_service_runtime_uid() {
  local service_path="$1"
  [[ -r "$service_path" ]] || return 1
  sed -nE 's#^Environment=XDG_RUNTIME_DIR=/run/user/([0-9]+)$#\1#p' "$service_path" | head -n1
}

get_wake_service_argument() {
  [[ -r "$CEC_WAKE_SERVICE" ]] || return 1
  sed -nE 's#^ExecStart=.*[[:space:]]wake[[:space:]]+([0-9]+)[[:space:]]*$#\1#p' "$CEC_WAKE_SERVICE" | head -n1
}

configured_bt_ids_from_service() {
  local execstart helper vendor product
  execstart="$(get_service_execstart "$BT_WAKE_SERVICE" || true)"
  [[ -n "$execstart" ]] || return 1
  read -r helper vendor product _ <<<"$execstart"
  [[ -n "$vendor" && -n "$product" ]] || return 1
  printf '%s|%s|%s\n' "$helper" "$vendor" "$product"
}

infer_desktop_context_from_services() {
  [[ -n "$DESKTOP_USER" ]] || DESKTOP_USER="$(get_service_user "$CEC_SLEEP_SERVICE" || true)"
  [[ -n "$DESKTOP_UID" ]] || DESKTOP_UID="$(get_service_runtime_uid "$CEC_SLEEP_SERVICE" || true)"
  if [[ -n "$DESKTOP_USER" && -z "$DESKTOP_UID" ]] && id "$DESKTOP_USER" >/dev/null 2>&1; then
    DESKTOP_UID="$(id -u "$DESKTOP_USER")"
  fi
}

report_file_status() {
  local label="$1" path="$2"
  if [[ -e "$path" ]]; then
    printf 'OK   %s exists: %s\n' "$label" "$path"
    return 0
  fi
  printf 'FAIL %s missing: %s\n' "$label" "$path"
  return 1
}

report_service_installed() {
  local service_name="$1" service_path="$2"
  local failures=0
  if ! report_file_status "$service_name unit" "$service_path"; then
    failures=$((failures + 1))
  fi
  if systemctl is-enabled --quiet "$service_name" 2>/dev/null; then
    printf 'OK   %s enabled\n' "$service_name"
  else
    printf 'FAIL %s not enabled\n' "$service_name"
    failures=$((failures + 1))
  fi
  return "$failures"
}

report_cec_devices() {
  local found=0 dev
  for dev in /dev/cec*; do
    [[ -e "$dev" ]] || continue
    if (( found == 0 )); then
      printf 'OK   Detected CEC device(s):\n'
    fi
    printf '     %s\n' "$dev"
    found=1
  done
  if (( found == 0 )); then
    printf 'FAIL No /dev/cec* devices detected\n'
    return 1
  fi
  return 0
}

report_cecd_inventory() {
  local failures=0 active_state live_integer live_physical

  if [[ -z "$DESKTOP_USER" || -z "$DESKTOP_UID" ]]; then
    printf 'WARN Could not infer the desktop user context; skipping cecd D-Bus checks\n'
    return 0
  fi

  printf 'OK   Desktop user context: %s (UID %s)\n' "$DESKTOP_USER" "$DESKTOP_UID"

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

  active_state="$({ run_as_desktop_user busctl --user get-property "$CEC_DEST" "$CEC_OBJECT_PATH" "$CEC_INTERFACE" Active 2>/dev/null | awk 'NR==1 {print $2}'; } || true)"
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

  if [[ -n "${CEC_PHYSICAL_INTEGER:-}" && -n "$live_integer" && "$CEC_PHYSICAL_INTEGER" == "$live_integer" ]]; then
    printf 'OK   Stored CEC physical integer matches cecd\n'
  elif [[ -n "${CEC_PHYSICAL_INTEGER:-}" && -n "$live_integer" ]]; then
    printf 'FAIL Stored CEC physical integer (%s) does not match cecd (%s)\n' "$CEC_PHYSICAL_INTEGER" "$live_integer"
    failures=$((failures + 1))
  fi

  return "$failures"
}

report_state_inventory() {
  local failures=0 wake_argument

  if load_any_state_file; then
    printf 'OK   State file loaded: %s\n' "$STATE_SOURCE"
    if [[ "$STATE_SOURCE" == "$LEGACY_STATE_FILE" ]]; then
      printf 'WARN Using legacy state path; re-run --install to migrate state into %s\n' "$STATE_FILE"
    fi
  else
    printf 'WARN State file missing from %s and %s\n' "$STATE_FILE" "$LEGACY_STATE_FILE"
    return 0
  fi

  if [[ "${CONFIG_VERSION:-0}" != "$EXPECTED_CONFIG_VERSION" ]]; then
    printf 'WARN Config version is %s, expected %s\n' "${CONFIG_VERSION:-unknown}" "$EXPECTED_CONFIG_VERSION"
  fi

  if validate_physical_address "${CEC_PHYSICAL_ADDRESS:-}"; then
    printf 'OK   Stored CEC physical address: %s\n' "$CEC_PHYSICAL_ADDRESS"
  else
    printf 'FAIL Invalid stored CEC physical address: %s\n' "${CEC_PHYSICAL_ADDRESS:-missing}"
    failures=$((failures + 1))
  fi

  if ! validate_physical_integer "${CEC_PHYSICAL_INTEGER:-}"; then
    if [[ "${CEC_PHYSICAL_INTEGER:-}" =~ ^[0-9]+$ ]] && (( CEC_PHYSICAL_INTEGER > 65535 )); then
      printf 'FAIL This installation was created by a version with the old CEC address conversion bug. Re-run --install to repair it.\n'
    else
      printf 'FAIL Invalid stored CEC physical address integer: %s\n' "${CEC_PHYSICAL_INTEGER:-missing}"
    fi
    failures=$((failures + 1))
  else
    printf 'OK   Stored CEC physical integer: %s\n' "$CEC_PHYSICAL_INTEGER"
  fi

  if [[ -n "${CEC_DEVICE:-}" ]]; then
    printf 'OK   Stored CEC device: %s\n' "$CEC_DEVICE"
  fi

  wake_argument="$(get_wake_service_argument || true)"
  if [[ -n "$wake_argument" ]]; then
    printf 'OK   cec-wake.service SetActiveSource argument: %s\n' "$wake_argument"
  else
    printf 'FAIL Could not parse the wake helper argument from %s\n' "$CEC_WAKE_SERVICE"
    failures=$((failures + 1))
  fi

  if [[ -n "${CEC_PHYSICAL_INTEGER:-}" && -n "$wake_argument" && "$CEC_PHYSICAL_INTEGER" == "$wake_argument" ]]; then
    printf 'OK   Wake service argument matches the stored CEC physical integer\n'
  elif [[ -n "${CEC_PHYSICAL_INTEGER:-}" && -n "$wake_argument" ]]; then
    printf 'FAIL Wake service argument (%s) does not match the stored CEC physical integer (%s)\n' "$wake_argument" "$CEC_PHYSICAL_INTEGER"
    failures=$((failures + 1))
  fi

  return "$failures"
}

report_bt_hardware_inventory() {
  local configured vendor product helper matched=0 dev wake failures=0
  local path class subclass protocol manufacturer name
  local candidates=()

  mapfile -t candidates < <(list_bt_candidates)
  if ((${#candidates[@]} > 0)); then
    printf 'OK   Detected Bluetooth HCI controller USB parent(s):\n'
    for configured in "${candidates[@]}"; do
      IFS='|' read -r path vendor product class subclass protocol manufacturer name <<<"$configured"
      printf '     %s  %s:%s  %s %s\n' "$path" "$vendor" "$product" "$manufacturer" "$name"
    done
  else
    printf 'FAIL No Bluetooth HCI controller with a USB parent was detected\n'
    return 1
  fi

  configured="$(configured_bt_ids_from_service || true)"
  if [[ -n "$configured" ]]; then
    IFS='|' read -r helper vendor product <<<"$configured"
    printf 'OK   Configured Bluetooth wake target: %s:%s\n' "$vendor" "$product"
    printf 'OK   bt-wakeup helper path: %s\n' "$helper"
  elif [[ -n "${BT_VENDOR:-}" && -n "${BT_PRODUCT:-}" ]]; then
    vendor="$BT_VENDOR"
    product="$BT_PRODUCT"
    printf 'OK   Stored Bluetooth wake target: %s:%s\n' "$vendor" "$product"
  else
    printf 'WARN No configured Bluetooth vendor/product IDs were found\n'
    return 0
  fi

  for dev in /sys/bus/usb/devices/*; do
    [[ -f "$dev/idVendor" && -f "$dev/idProduct" ]] || continue
    [[ "$(basename "$dev")" == *:* ]] && continue
    [[ "$(<"$dev/idVendor")" == "$vendor" && "$(<"$dev/idProduct")" == "$product" ]] || continue
    matched=1
    wake="$(cat "$dev/power/wakeup" 2>/dev/null || echo unavailable)"
    if [[ "$wake" == "enabled" ]]; then
      printf 'OK   %s (%s:%s) wakeup enabled\n' "$(basename "$dev")" "$vendor" "$product"
    else
      printf 'FAIL %s (%s:%s) wakeup is %s\n' "$(basename "$dev")" "$vendor" "$product" "$wake"
      failures=$((failures + 1))
    fi
  done

  if (( matched == 0 )); then
    printf 'FAIL Bluetooth device %s:%s not found\n' "$vendor" "$product"
    failures=$((failures + 1))
  fi

  return "$failures"
}

keep_list_covers_path() {
  local path="$1"
  [[ -r "$ATOMIC_UPDATE_KEEP_FILE" ]] || return 1
  grep -Fqx "$path" "$ATOMIC_UPDATE_KEEP_FILE"
}

verify_atomic_keep_list() {
  local failures=0 path
  local required_paths=()
  mapfile -t required_paths < <(atomic_keep_paths)

  if [[ -r "$ATOMIC_UPDATE_KEEP_FILE" ]]; then
    printf 'OK   Atomic-update keep-list exists: %s\n' "$ATOMIC_UPDATE_KEEP_FILE"
  else
    printf 'FAIL Atomic-update keep-list missing: %s\n' "$ATOMIC_UPDATE_KEEP_FILE"
    return 1
  fi

  for path in "${required_paths[@]}"; do
    if keep_list_covers_path "$path"; then
      printf 'OK   Keep-list preserves %s\n' "$path"
    else
      printf 'FAIL Keep-list missing %s\n' "$path"
      failures=$((failures + 1))
    fi
  done

  for path in "$CEC_SLEEP_SERVICE" "$CEC_WAKE_SERVICE" "$BT_WAKE_SERVICE" "$BT_WAKE_RULE" "$MTK_RULE" "$ATOMIC_UPDATE_KEEP_FILE"; do
    if [[ -e "$path" ]]; then
      if keep_list_covers_path "$path"; then
        printf 'OK   Keep-list covers installed path %s\n' "$path"
      else
        printf 'FAIL Keep-list does not cover installed path %s\n' "$path"
        failures=$((failures + 1))
      fi
    fi
  done

  if [[ -e "$LEGACY_STATE_FILE" ]]; then
    if keep_list_covers_path "$LEGACY_STATE_FILE"; then
      printf 'OK   Keep-list covers legacy path %s\n' "$LEGACY_STATE_FILE"
    else
      printf 'FAIL Keep-list does not cover legacy path %s\n' "$LEGACY_STATE_FILE"
      failures=$((failures + 1))
    fi
  fi

  if [[ -d "$LEGACY_HELPER_DIR" ]]; then
    if keep_list_covers_path "$LEGACY_HELPER_DIR/**"; then
      printf 'OK   Keep-list covers legacy directory %s/**\n' "$LEGACY_HELPER_DIR"
    else
      printf 'FAIL Keep-list does not cover legacy directory %s/**\n' "$LEGACY_HELPER_DIR"
      failures=$((failures + 1))
    fi
  fi

  return "$failures"
}

report_holo_sync_var_status() {
  local output rc=0 path matched=0
  local project_paths=(
    "$CEC_SLEEP_SERVICE"
    "$CEC_WAKE_SERVICE"
    "$BT_WAKE_SERVICE"
    "$BT_WAKE_RULE"
    "$MTK_RULE"
    "$ATOMIC_UPDATE_KEEP_FILE"
    "$LEGACY_STATE_FILE"
    "$LEGACY_HELPER_DIR"
    "$STATE_FILE"
    "$CEC_HELPER"
    "$BT_HELPER"
  )

  if [[ ! -x /usr/lib/holo/holo-sync-var ]]; then
    printf 'WARN /usr/lib/holo/holo-sync-var not available; skipped SteamOS update dry-run\n'
    return 0
  fi

  output="$(/usr/lib/holo/holo-sync-var --dry-run all 2>&1)" || rc=$?
  if (( rc != 0 )); then
    printf 'WARN /usr/lib/holo/holo-sync-var --dry-run all failed with exit code %d\n' "$rc"
    return 0
  fi

  for path in "${project_paths[@]}"; do
    if grep -Fq "$path" <<<"$output"; then
      if (( matched == 0 )); then
        printf 'WARN SteamOS dry-run reported project paths that may be discarded by the next update:\n'
      fi
      printf '     %s\n' "$path"
      matched=1
    fi
  done

  if (( matched == 0 )); then
    printf 'OK   SteamOS dry-run did not report project-managed paths as discard candidates\n'
  fi
}

verify() {
  local failures=0 state_rc service_rc bt_rc cecd_rc keep_rc partial_damage=0

  DESKTOP_USER=""
  DESKTOP_UID=""
  STATE_SOURCE=""
  CEC_PHYSICAL_ADDRESS="${CEC_PHYSICAL_ADDRESS:-}"
  CEC_PHYSICAL_INTEGER="${CEC_PHYSICAL_INTEGER:-}"
  BT_VENDOR="${BT_VENDOR:-}"
  BT_PRODUCT="${BT_PRODUCT:-}"

  load_any_state_file || true
  infer_desktop_context_from_services
  if [[ -n "${CEC_DEVICE:-}" ]]; then
    configure_cec_device
  fi

  printf '\nLayout\n------\n'
  if [[ -d "$VAR_LIB_DIR" ]]; then
    printf 'OK   Persistent data directory exists: %s\n' "$VAR_LIB_DIR"
  else
    printf 'FAIL Persistent data directory missing: %s\n' "$VAR_LIB_DIR"
    failures=$((failures + 1))
  fi

  if report_file_status "CEC helper" "$CEC_HELPER"; then :; else failures=$((failures + 1)); partial_damage=1; fi
  if report_file_status "Bluetooth helper" "$BT_HELPER"; then :; else failures=$((failures + 1)); partial_damage=1; fi

  if [[ -e "$LEGACY_CEC_HELPER" || -e "$LEGACY_BT_HELPER" || -e "$LEGACY_STATE_FILE" ]]; then
    printf 'WARN Legacy /etc install paths still exist. Re-running --install migrates the active layout to %s.\n' "$VAR_LIB_DIR"
  fi

  printf '\nCEC\n---\n'
  if report_cec_devices; then :; else failures=$((failures + 1)); fi
  report_state_inventory
  state_rc=$?
  failures=$((failures + state_rc))
  (( state_rc > 0 )) && partial_damage=1

  report_service_installed cec-sleep.service "$CEC_SLEEP_SERVICE"
  service_rc=$?
  failures=$((failures + service_rc))
  (( service_rc > 0 )) && partial_damage=1

  report_service_installed cec-wake.service "$CEC_WAKE_SERVICE"
  service_rc=$?
  failures=$((failures + service_rc))
  (( service_rc > 0 )) && partial_damage=1

  report_cecd_inventory
  cecd_rc=$?
  failures=$((failures + cecd_rc))

  printf '\nBluetooth wake\n--------------\n'
  report_service_installed bt-wakeup.service "$BT_WAKE_SERVICE"
  service_rc=$?
  failures=$((failures + service_rc))
  (( service_rc > 0 )) && partial_damage=1

  if report_file_status "Bluetooth udev rule" "$BT_WAKE_RULE"; then :; else failures=$((failures + 1)); partial_damage=1; fi
  if [[ -e "$MTK_RULE" ]]; then
    printf 'OK   Optional MediaTek rule exists: %s\n' "$MTK_RULE"
  else
    printf 'WARN Optional MediaTek rule not installed\n'
  fi

  report_bt_hardware_inventory
  bt_rc=$?
  failures=$((failures + bt_rc))

  printf '\nSteamOS atomic updates\n----------------------\n'
  verify_atomic_keep_list
  keep_rc=$?
  failures=$((failures + keep_rc))
  report_holo_sync_var_status

  if [[ -z "$STATE_SOURCE" ]] && ([[ -e "$CEC_SLEEP_SERVICE" ]] || [[ -e "$CEC_WAKE_SERVICE" ]] || [[ -e "$BT_WAKE_SERVICE" ]] || [[ -e "$BT_WAKE_RULE" ]] || [[ -e "$CEC_HELPER" ]] || [[ -e "$BT_HELPER" ]]); then
    partial_damage=1
    printf 'WARN Recoverable partial-install damage detected: project files exist but the state file is missing. Re-run --install to regenerate %s.\n' "$STATE_FILE"
  fi

  if (( partial_damage == 1 )); then
    printf 'WARN Recoverable partial-install damage was detected. Re-running --install should repair missing project-managed files.\n'
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
    "$BT_WAKE_RULE" "$MTK_RULE" "$STATE_FILE" "$LEGACY_STATE_FILE" \
    "$CEC_HELPER" "$BT_HELPER" "$LEGACY_CEC_HELPER" "$LEGACY_BT_HELPER"
  remove_atomic_update_keep_list
  rmdir "$VAR_LIB_DIR" 2>/dev/null || true
  rmdir "$LEGACY_HELPER_DIR" 2>/dev/null || true
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
      verify
      exit $?
      ;;
  esac

  command_exists systemctl || die "systemd is required."
  command_exists gdbus || die "gdbus is required."
  command_exists udevadm || die "udevadm is required."
  command_exists busctl || die "busctl is required."
  command_exists runuser || die "runuser is required."

  migrate_legacy_layout
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
  Persistent layout:  $VAR_LIB_DIR
SUMMARY

  confirm "Install this configuration?" || die "Cancelled."

  write_atomic_update_keep_list
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
