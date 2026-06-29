#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../steamos-cec-bt-wake.sh
source "$REPO_DIR/steamos-cec-bt-wake.sh"

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL %s: expected %s, got %s\n' "$label" "$expected" "$actual" >&2
    exit 1
  fi
}

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

verify_tmpdir="$(mktemp -d)"
verify_output="$(
  REPO_DIR="$REPO_DIR" TMPDIR="$verify_tmpdir" bash <<'EOF2'
set -euo pipefail
# shellcheck source=../steamos-cec-bt-wake.sh
source "$REPO_DIR/steamos-cec-bt-wake.sh"

tmpdir="$TMPDIR"
STATE_FILE="$tmpdir/state.conf"
CEC_HELPER="$tmpdir/cec-control"
CEC_WAKE_SERVICE="$tmpdir/cec-wake.service"
BT_WAKE_RULE="$tmpdir/91-bluetooth-wakeup.rules"
CEC_DEVICE="$tmpdir/cec0"
touch "$CEC_HELPER" "$BT_WAKE_RULE" "$CEC_DEVICE"

cat > "$STATE_FILE" <<EOF3
CONFIG_VERSION=2
DESKTOP_USER=deck
DESKTOP_UID=1000
CEC_DEVICE=$CEC_DEVICE
CEC_OBJECT_PATH=/com/steampowered/CecDaemon1/Devices/Cec0
CEC_PHYSICAL_ADDRESS=3.0.0.0
CEC_PHYSICAL_INTEGER=12288
BT_VENDOR=
BT_PRODUCT=
EOF3

cat > "$CEC_WAKE_SERVICE" <<EOF3
[Service]
ExecStart=$CEC_HELPER wake 12288
EOF3

systemctl() {
  [[ "$1" == "is-enabled" ]] && return 0
  return 1
}

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

configure_cec_device() {
  :
}

verify
EOF2
)"
rm -rf "$verify_tmpdir"
assert_contains "$verify_output" "OK   com.steampowered.CecDaemon1 is reachable on the user session bus" "verify treats readable Active property as reachable"
assert_contains "$verify_output" "WARN cecd Active property is false" "verify warns on Active=false"
assert_not_contains "$verify_output" "FAIL Could not reach the CEC D-Bus object on the user session bus" "verify does not misreport D-Bus reachability"

printf 'All CEC helper and verification regression tests passed.\n'
