#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES_DIR="$REPO_DIR/tests/fixtures"

# shellcheck source=../steamos-cec-bt-wake.sh
source "$REPO_DIR/steamos-cec-bt-wake.sh"

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL %s: expected %s, got %s\n' "$label" "$expected" "$actual" >&2
    exit 1
  fi
}

assert_empty() {
  local actual="$1" label="$2"
  if [[ -n "$actual" ]]; then
    printf 'FAIL %s: expected empty output, got %s\n' "$label" "$actual" >&2
    exit 1
  fi
}

assert_eq 4096 "$(physical_to_integer 1.0.0.0)" "1.0.0.0 -> 4096"
assert_eq 8192 "$(physical_to_integer 2.0.0.0)" "2.0.0.0 -> 8192"
assert_eq 12288 "$(physical_to_integer 3.0.0.0)" "3.0.0.0 -> 12288"
assert_eq 4660 "$(physical_to_integer 1.2.3.4)" "1.2.3.4 -> 4660"
assert_eq 65535 "$(physical_to_integer f.f.f.f)" "f.f.f.f -> 65535"

assert_eq 4096 "$(physical_to_integer 1.0.0.0)" "1.0.0.0 conversion"
assert_eq "3.0.0.0" "$(integer_to_physical 12288)" "12288 -> 3.0.0.0"
assert_eq "f.f.f.f" "$(integer_to_physical 65535)" "65535 -> f.f.f.f"

assert_eq "3.0.0.0" "$(parse_cec_physical_address_from_output < "$FIXTURES_DIR/cec-ctl-valid.txt")" "strict parse of valid cec-ctl output"
assert_eq "3.0.0.0" "$(parse_cec_physical_address_from_output < "$FIXTURES_DIR/cec-ctl-noisy.txt")" "strict parse ignores unrelated dotted addresses"
assert_empty "$(parse_cec_physical_address_from_output <<<"Adapter reports 1.2.3.4 but no labeled field")" "parser rejects unlabeled address"

printf 'All CEC address regression tests passed.\n'
