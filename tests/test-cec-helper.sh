#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../steamos-cec-bt-wake.sh
source "$REPO_DIR/steamos-cec-bt-wake.sh"

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'FAIL %s: missing %s\n' "$label" "$needle" >&2
    exit 1
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" label="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'FAIL %s: unexpectedly found %s\n' "$label" "$needle" >&2
    exit 1
  fi
}

run_generated_helper_test() {
  local body="$1"
  local helper_file
  helper_file="$(mktemp)"
  CEC_DEST="com.test.CecDaemon1"
  CEC_OBJECT_PATH="/com/test/CecDaemon1/Devices/Cec0"
  CEC_INTERFACE="com.test.CecDevice1"
  generate_cec_helper_content > "$helper_file"

  HELPER_FILE="$helper_file" BODY="$body" bash <<'EOF2'
set -euo pipefail
set -- standby
# shellcheck disable=SC1090
source "$HELPER_FILE"
CEC_DEST="com.test.CecDaemon1"
CEC_OBJECT_PATH="/com/test/CecDaemon1/Devices/Cec0"
CEC_INTERFACE="com.test.CecDevice1"
eval "$BODY"
EOF2
  rm -f "$helper_file"
}

stdin_output="$(bash -s -- --help < "$REPO_DIR/steamos-cec-bt-wake.sh")"
assert_contains "$stdin_output" "Usage:" "stdin execution prints help"

wait_success_output="$(
  run_generated_helper_test '
attempts=0
sleeps=0
busctl() {
  attempts=$((attempts + 1))
  [[ "$1" == "--user" && "$2" == "get-property" ]]
}
sleep() {
  sleeps=$((sleeps + 1))
}
wait_for_cecd_object
printf "attempts=%s sleeps=%s\n" "$attempts" "$sleeps"
'
)"
assert_contains "$wait_success_output" "attempts=1 sleeps=0" "wait_for_cecd_object succeeds immediately"

wait_failure_output="$(
  run_generated_helper_test '
attempts=0
sleeps=0
busctl() {
  attempts=$((attempts + 1))
  return 1
}
sleep() {
  sleeps=$((sleeps + 1))
}
set +e
wait_for_cecd_object
rc=$?
set -e
printf "rc=%s attempts=%s sleeps=%s\n" "$rc" "$attempts" "$sleeps"
'
)"
assert_contains "$wait_failure_output" "rc=1 attempts=10 sleeps=10" "wait_for_cecd_object times out after configured retries"

call_failure_output="$(
  run_generated_helper_test '
attempts_file=$(mktemp)
printf "0" > "$attempts_file"
gdbus() {
  local attempts
  attempts=$(<"$attempts_file")
  attempts=$((attempts + 1))
  printf "%s" "$attempts" > "$attempts_file"
  printf "non-nack failure\n" >&2
  return 7
}
set +e
call_cec Wake
rc=$?
set -e
printf "rc=%s attempts=%s\n" "$rc" "$(cat "$attempts_file")"
rm -f "$attempts_file"
'
)"
assert_contains "$call_failure_output" "rc=7 attempts=1" "call_cec returns real non-NACK status"

call_retry_output="$(
  run_generated_helper_test '
attempts_file=$(mktemp)
printf "0" > "$attempts_file"
sleeps=0
gdbus() {
  local attempts
  attempts=$(<"$attempts_file")
  attempts=$((attempts + 1))
  printf "%s" "$attempts" > "$attempts_file"
  if (( attempts < 3 )); then
    printf "TxError.Nack: No acknowledgement\n" >&2
    return 1
  fi
  printf "(true,)\n"
}
sleep() {
  sleeps=$((sleeps + 1))
}
call_cec Wake >/dev/null
printf "attempts=%s sleeps=%s\n" "$(cat "$attempts_file")" "$sleeps"
rm -f "$attempts_file"
'
)"
assert_contains "$call_retry_output" "attempts=3 sleeps=2" "call_cec retries NACK and succeeds later"

cecd_inventory_output="$(
  REPO_DIR="$REPO_DIR" bash <<'EOF2'
set -euo pipefail
# shellcheck source=../steamos-cec-bt-wake.sh
source "$REPO_DIR/steamos-cec-bt-wake.sh"

DESKTOP_USER=deck
DESKTOP_UID=1000
CEC_OBJECT_PATH=/com/steampowered/CecDaemon1/Devices/Cec0
CEC_PHYSICAL_INTEGER=12288

run_as_desktop_user() {
  if [[ "$1" == "systemctl" ]]; then
    [[ "$2" == "--user" && "$3" == "is-active" ]] && return 0
  fi

  if [[ "$1" == "busctl" && "$2" == "--user" && "$3" == "get-property" ]]; then
    case "$7" in
      Active)
        printf 'b false\n'
        return 0
        ;;
      PhysicalAddress)
        printf 'q 12288\n'
        return 0
        ;;
    esac
  fi

  return 1
}

report_cecd_inventory
EOF2
)"
assert_contains "$cecd_inventory_output" "OK   com.steampowered.CecDaemon1 is reachable on the user session bus" "report_cecd_inventory treats readable Active property as reachable"
assert_contains "$cecd_inventory_output" "WARN cecd Active property is false" "report_cecd_inventory warns on Active=false"
assert_not_contains "$cecd_inventory_output" "FAIL Could not reach the CEC D-Bus object on the user session bus" "report_cecd_inventory does not misreport D-Bus reachability"

verify_without_state_output="$(
  REPO_DIR="$REPO_DIR" TMPDIR="$(mktemp -d)" bash <<'EOF2'
set -euo pipefail
# shellcheck source=../steamos-cec-bt-wake.sh
source "$REPO_DIR/steamos-cec-bt-wake.sh"

tmpdir="$TMPDIR"
VAR_LIB_DIR="$tmpdir/varlib"
STATE_FILE="$VAR_LIB_DIR/state.conf"
LEGACY_STATE_FILE="$tmpdir/etc/steamos-cec-bt-wake.conf"
CEC_HELPER="$VAR_LIB_DIR/cec-control"
BT_HELPER="$VAR_LIB_DIR/enable-bluetooth-wakeup"
CEC_SLEEP_SERVICE="$tmpdir/etc/systemd/system/cec-sleep.service"
CEC_WAKE_SERVICE="$tmpdir/etc/systemd/system/cec-wake.service"
BT_WAKE_SERVICE="$tmpdir/etc/systemd/system/bt-wakeup.service"
BT_WAKE_RULE="$tmpdir/etc/udev/rules.d/91-bluetooth-wakeup.rules"
MTK_RULE="$tmpdir/etc/udev/rules.d/99-btusb-mediatek.rules"
ATOMIC_UPDATE_KEEP_FILE="$tmpdir/etc/atomic-update.conf.d/steamos-cec-bt-wake.conf"

install -d -m 0755 "$VAR_LIB_DIR" "$(dirname "$CEC_SLEEP_SERVICE")" "$(dirname "$BT_WAKE_RULE")" "$(dirname "$ATOMIC_UPDATE_KEEP_FILE")"
printf '#!/usr/bin/env bash\n' > "$CEC_HELPER"
printf '#!/usr/bin/env bash\n' > "$BT_HELPER"
chmod 0755 "$CEC_HELPER" "$BT_HELPER"
cat > "$CEC_SLEEP_SERVICE" <<EOF3
[Service]
User=deck
Environment=XDG_RUNTIME_DIR=/run/user/1000
ExecStart=$CEC_HELPER standby
EOF3
cat > "$CEC_WAKE_SERVICE" <<EOF3
[Service]
User=deck
Environment=XDG_RUNTIME_DIR=/run/user/1000
ExecStart=$CEC_HELPER wake 12288
EOF3
cat > "$BT_WAKE_SERVICE" <<EOF3
[Service]
ExecStart=$BT_HELPER 0e8d 0616
EOF3
printf 'rule\n' > "$BT_WAKE_RULE"
printf 'keep\n' > "$ATOMIC_UPDATE_KEEP_FILE"

systemctl() {
  [[ "$1" == "is-enabled" ]]
}

report_cec_devices() {
  printf 'OK   Detected CEC device(s):\n'
  printf '     /dev/cec0\n'
}

report_cecd_inventory() {
  printf 'OK   cecd inventory mocked\n'
}

report_bt_hardware_inventory() {
  printf 'OK   Bluetooth inventory mocked\n'
}

verify_atomic_keep_list() {
  printf 'OK   Atomic-update keep-list exists: %s\n' "$ATOMIC_UPDATE_KEEP_FILE"
}

report_holo_sync_var_status() {
  printf 'OK   SteamOS dry-run did not report project-managed paths as discard candidates\n'
}

set +e
verify
rc=$?
set -e
printf 'rc=%s\n' "$rc"
rm -rf "$tmpdir"
EOF2
)"
assert_contains "$verify_without_state_output" "WARN State file missing" "verify warns when no state file exists"
assert_contains "$verify_without_state_output" "WARN Recoverable partial-install damage detected: project files exist but the state file is missing." "verify reports recoverable partial-install damage"
assert_contains "$verify_without_state_output" "rc=0" "verify succeeds when state is missing but the rest of the install is intact"

keep_list_output="$(
  REPO_DIR="$REPO_DIR" TMPDIR="$(mktemp -d)" bash <<'EOF2'
set -euo pipefail
# shellcheck source=../steamos-cec-bt-wake.sh
source "$REPO_DIR/steamos-cec-bt-wake.sh"
ATOMIC_UPDATE_KEEP_FILE="$TMPDIR/steamos-cec-bt-wake.conf"
ATOMIC_UPDATE_KEEP_DIR="$TMPDIR"
write_atomic_update_keep_list
read -r content < "$ATOMIC_UPDATE_KEEP_FILE" || true
cat "$ATOMIC_UPDATE_KEEP_FILE"
rm -rf "$TMPDIR"
EOF2
)"
assert_contains "$keep_list_output" "/etc/steamos-cec-bt-wake.conf" "keep-list preserves legacy state path"
assert_contains "$keep_list_output" "/etc/steamos-cec-bt-wake/**" "keep-list preserves legacy helper directory"
assert_contains "$keep_list_output" "/etc/systemd/system/cec-sleep.service" "keep-list preserves cec-sleep.service"
assert_contains "$keep_list_output" "/etc/udev/rules.d/99-btusb-mediatek.rules" "keep-list preserves optional MediaTek rule"
assert_contains "$keep_list_output" "/etc/atomic-update.conf.d/steamos-cec-bt-wake.conf" "keep-list preserves itself"

printf 'All CEC helper and verification regression tests passed.\n'
