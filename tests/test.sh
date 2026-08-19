#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_NAME="3xui-warp-router"
source "$ROOT_DIR/3xui-warp-router.sh"
SCRIPT_NAME="3xui-warp-router"

TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_TMPDIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1" needle="$2"
  [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain: $needle"
}

assert_not_contains() {
  local haystack="$1" needle="$2"
  [[ "$haystack" != *"$needle"* ]] || fail "expected output not to contain: $needle"
}

probe_cfg="$TEST_TMPDIR/warp-config.json"
printf '%s\n' '{"outbounds":[{"tag":"warp","protocol":"wireguard"}]}' >"$probe_cfg"
last_probe_args=()
api_post_obj_json() {
  last_probe_args=("$@")
  printf '%s\n' '{"success":true}'
}

outbound_probe_json "$probe_cfg" >/dev/null || fail "default outbound probe should succeed"
assert_contains "${last_probe_args[*]}" "mode=real"
outbound_probe_json "$probe_cfg" http >/dev/null || fail "HTTP outbound probe should succeed"
assert_contains "${last_probe_args[*]}" "mode=http"
assert_not_contains "${last_probe_args[*]}" "mode=real"

cfg_file="$TEST_TMPDIR/config.json"
printf '%s\n' '{"inbounds":[{"tag":"api","protocol":"dokodemo-door"},{"tag":"in-28193-tcp","protocol":"vless","sniffing":{"enabled":false}},{"tag":"in-enabled","protocol":"vless","sniffing":{"enabled":true}}],"outbounds":[]}' >"$cfg_file"

if apply_output="$(check_inbound_sniffing "$cfg_file" apply 2>&1)"; then
  fail "disabled client inbound should produce a warning status"
fi
assert_contains "$apply_output" "WARNING: inbound in-28193-tcp has sniffing disabled."
assert_contains "$apply_output" "WARNING: Domain-based WARP routing may not work when clients send resolved IP addresses."
assert_not_contains "$apply_output" "inbound api has sniffing disabled"

if test_output="$(check_inbound_sniffing "$cfg_file" test 2>&1)"; then
  fail "disabled client inbound should produce a test warning status"
fi
assert_contains "$test_output" "Inbound sniffing"
assert_contains "$test_output" "in-28193-tcp disabled"

enabled_cfg="$TEST_TMPDIR/enabled-config.json"
printf '%s\n' '{"inbounds":[{"tag":"api","protocol":"dokodemo-door"},{"tag":"in-enabled","protocol":"vless","sniffing":{"enabled":true}}],"outbounds":[]}' >"$enabled_cfg"
enabled_output="$(check_inbound_sniffing "$enabled_cfg" test 2>&1)" || fail "enabled client inbounds should pass the sniffing check"
assert_contains "$enabled_output" "enabled on 1 client inbound(s)"

route_decision_json() {
  case "$1" in
    www.google.com) printf '%s\n' '{"matched":true,"outboundTag":"warp"}' ;;
    www.youtube.com) printf '%s\n' '{"matched":true,"outboundTag":"direct"}' ;;
    *) printf '%s\n' '{"matched":false}' ;;
  esac
}

wait_for_route_api() { return 0; }
outbound_test() { return 0; }

PROFILE="google-web"
YOUTUBE_MODE="direct"
post_apply_output="$(post_apply_test "$cfg_file" direct 2>&1)" || fail "post-apply route test should pass with valid route results"
assert_contains "$post_apply_output" "www.youtube.com"
assert_contains "$post_apply_output" "direct (expected direct/default)"
assert_not_contains "$post_apply_output" "jq: parse error"

printf 'All 3xui-warp-router tests passed.\n'
