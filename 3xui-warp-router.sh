#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

VERSION="0.3.2"
SCRIPT_NAME="${0##*/}"

API_BASE="${XUI_API_BASE:-}"
API_TOKEN="${XUI_API_TOKEN:-}"
TOKEN_FILE="${XUI_API_TOKEN_FILE:-}"
PROFILE="${XUI_WARP_PROFILE:-}"
YOUTUBE_MODE="${XUI_YOUTUBE_MODE:-}"
PRIORITY="${XUI_WARP_PRIORITY:-}"
DIRECT_TAG_OVERRIDE="${XUI_DIRECT_TAG:-}"
CUSTOM_FILE=""
STATE_DIR="${XUI_WARP_STATE_DIR:-}"
INSECURE="${XUI_WARP_INSECURE:-}"
AUTO_ROLLBACK=1
ROTATE_DAYS=""
COMMAND=""

CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
DEFAULT_CONFIG_DIR="${CONFIG_HOME%/}/3xui-warp-router"
CONFIG_FILE="${XUI_WARP_CONFIG_FILE:-$DEFAULT_CONFIG_DIR/config}"
CONFIG_DISABLED=0

# Legacy domain markers used by v0.3.1 and earlier.  Keep recognizing them so
# an apply/remove operation can migrate or clean up previously generated rules.
MARKER_WARP="full:xui-warp-router-warp.invalid"
MARKER_DIRECT="full:xui-warp-router-direct.invalid"

# Xray supports ruleTag as a non-matching identifier.  New managed rules use
# it instead of putting a synthetic domain token into the real domain list.
RULE_TAG_WARP="xui-warp-router-warp"
RULE_TAG_DIRECT="xui-warp-router-direct"

CURL_COMMON=(
  --silent --show-error
  --connect-timeout 8
  --max-time 45
  -H "Accept: application/json"
)

RUN_TMPDIR=""
cleanup() {
  if [[ -n "$RUN_TMPDIR" && -d "$RUN_TMPDIR" ]]; then
    rm -rf -- "$RUN_TMPDIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT

init_run_tmpdir() {
  RUN_TMPDIR="$(mktemp -d "$STATE_DIR/.run.XXXXXX")"
  chmod 700 "$RUN_TMPDIR" 2>/dev/null || true
}

new_tmp() {
  local f
  if [[ -n "$RUN_TMPDIR" && -d "$RUN_TMPDIR" ]]; then
    f="$(mktemp "$RUN_TMPDIR/file.XXXXXX")"
  else
    f="$(mktemp)"
  fi
  chmod 600 "$f" 2>/dev/null || true
  printf '%s\n' "$f"
}

log()  { printf '[%s] %s\n' "$SCRIPT_NAME" "$*" >&2; }
warn() { printf '[%s] WARNING: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
3xui-warp-router.sh - 3x-ui native WARP routing manager

Usage:
  3xui-warp-router.sh <command> [options]

Commands:
  configure     Save API base + token file securely for future invocations
  install       Ensure native 3x-ui WARP outbound exists, then apply routing
  bootstrap     Ensure native 3x-ui WARP account/outbound exists, no route changes
  apply         Apply/update managed routing rules; requires a warp outbound
  status        Show WARP outbound, routing, and auto-rotation state
  test          Test the currently installed managed rules and WARP connectivity
  diagnose      Read-only health report for API, Xray, WARP, routes, and rotation
  rotate        Ask 3x-ui to rotate WARP IP, then test current installed rules
  rotation      Show or set 3x-ui WARP auto-rotation without changing routing
  remove        Remove only routing rules managed by this script
  rollback      Restore the latest local Xray-config backup
  backups       List local backups

Connection settings (precedence: CLI > environment > config file > prompt):
  --api-base URL      Base URL ending in /panel/api
                      Example: https://panel.example.com:2053/panel/api
                      With web base path: https://host:2053/secret/panel/api
                      Env: XUI_API_BASE
  --token-file FILE   Read API token from a mode-0600 file
                      Env: XUI_API_TOKEN_FILE
  --config FILE       Config file (default: ~/.config/3xui-warp-router/config)
  --no-config         Do not load the default/configured config file
  API token           Env XUI_API_TOKEN. If still unavailable on a TTY,
                      the script prompts without echoing it.

Routing options:
  --profile NAME      google-web (default), gemini, google-all, custom
  --youtube MODE      direct (default) or warp
  --custom-file FILE  One Xray domain token per line for profile=custom.
                      Example: domain:example.com, full:foo.example.com,
                      geosite:google. Blank lines and # comments are ignored.
  --priority MODE     prepend (default) or append relative to existing user rules
  --direct-tag TAG    Explicit freedom outbound tag. Otherwise auto-detected.
  --rotate-days N     Set 3x-ui WARP auto-rotation interval in days (0 disables)

Safety options:
  --insecure          Disable TLS certificate verification for the panel API
  --no-auto-rollback  Keep a failed apply instead of restoring the pre-change backup
  --state-dir DIR     Backup/state directory
  -h, --help          Show this help

Examples:
  ./3xui-warp-router.sh configure --api-base 'https://panel.example.com:2053/panel/api'
  ./3xui-warp-router.sh install --profile google-web --youtube direct
  ./3xui-warp-router.sh diagnose
  ./3xui-warp-router.sh test
  ./3xui-warp-router.sh rotate
  ./3xui-warp-router.sh rotation --rotate-days 7

Notes:
  * Initial WARP registration prefers the Xray-core `wg` subcommand already
    shipped with 3x-ui. The system `wg` command is only a fallback.
  * The script never edits x-ui.db directly.
  * diagnose is read-only and never changes routes, WARP registration, or IP.
  * Backups contain the Xray config, including WARP private-key material.
    They are stored with mode 0600 inside a 0700 directory.
USAGE
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

trim_space() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

preparse_config_args() {
  local args=("$@") i=1
  while (( i < ${#args[@]} )); do
    case "${args[$i]}" in
      --config)
        (( i + 1 < ${#args[@]} )) || die "--config requires a value"
        CONFIG_FILE="${args[$((i + 1))]}"
        i=$((i + 2))
        ;;
      --no-config)
        CONFIG_DISABLED=1
        i=$((i + 1))
        ;;
      *) i=$((i + 1)) ;;
    esac
  done
}

load_config_file() {
  (( CONFIG_DISABLED )) && return 0
  [[ -f "$CONFIG_FILE" ]] || return 0

  local raw key value
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    raw="${raw%$'\r'}"
    [[ "$raw" =~ ^[[:space:]]*$ ]] && continue
    [[ "$raw" =~ ^[[:space:]]*# ]] && continue
    [[ "$raw" == *=* ]] || { warn "Ignoring malformed config line in $CONFIG_FILE"; continue; }
    key="$(trim_space "${raw%%=*}")"
    value="$(trim_space "${raw#*=}")"
    case "$key" in
      api_base)   [[ -n "$API_BASE" ]] || API_BASE="$value" ;;
      token_file) [[ -n "$TOKEN_FILE" ]] || TOKEN_FILE="$value" ;;
      profile)    [[ -n "$PROFILE" ]] || PROFILE="$value" ;;
      youtube)    [[ -n "$YOUTUBE_MODE" ]] || YOUTUBE_MODE="$value" ;;
      priority)   [[ -n "$PRIORITY" ]] || PRIORITY="$value" ;;
      direct_tag) [[ -n "$DIRECT_TAG_OVERRIDE" ]] || DIRECT_TAG_OVERRIDE="$value" ;;
      state_dir)  [[ -n "$STATE_DIR" ]] || STATE_DIR="$value" ;;
      insecure)   [[ -n "$INSECURE" ]] || INSECURE="$value" ;;
      *) warn "Ignoring unknown config key '$key' in $CONFIG_FILE" ;;
    esac
  done <"$CONFIG_FILE"
}

finalize_defaults() {
  [[ -n "$PROFILE" ]] || PROFILE="google-web"
  [[ -n "$YOUTUBE_MODE" ]] || YOUTUBE_MODE="direct"
  [[ -n "$PRIORITY" ]] || PRIORITY="prepend"
  [[ -n "$STATE_DIR" ]] || STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/3xui-warp-router"
  case "${INSECURE,,}" in
    1|true|yes|on) INSECURE=1 ;;
    ''|0|false|no|off) INSECURE=0 ;;
    *) die "Invalid insecure value in environment/config: $INSECURE" ;;
  esac
}

validate_options() {
  case "$PROFILE" in google-web|gemini|google-all|custom) ;; *) die "Invalid --profile: $PROFILE" ;; esac
  case "$YOUTUBE_MODE" in direct|warp) ;; *) die "Invalid --youtube: $YOUTUBE_MODE" ;; esac
  case "$PRIORITY" in prepend|append) ;; *) die "Invalid --priority: $PRIORITY" ;; esac
}

normalize_api_base() {
  API_BASE="${API_BASE%/}"
  [[ -n "$API_BASE" ]] || {
    if [[ -t 0 ]]; then
      read -r -p "3x-ui API base (ending in /panel/api): " API_BASE
      API_BASE="${API_BASE%/}"
    fi
  }
  [[ -n "$API_BASE" ]] || die "Set XUI_API_BASE or pass --api-base"
  [[ "$API_BASE" =~ ^https?:// ]] || die "--api-base must start with http:// or https://"
  [[ "$API_BASE" == */panel/api ]] || warn "API base does not end in /panel/api; continuing because custom reverse-proxy layouts are possible"
}

ensure_token() {
  if [[ -z "$API_TOKEN" && -n "$TOKEN_FILE" ]]; then
    [[ -f "$TOKEN_FILE" ]] || die "API token file not found: $TOKEN_FILE"
    [[ -r "$TOKEN_FILE" ]] || die "API token file is not readable: $TOKEN_FILE"
    [[ ! -L "$TOKEN_FILE" ]] || warn "API token file is a symlink: $TOKEN_FILE"
    local mode
    mode="$(stat -c '%a' "$TOKEN_FILE" 2>/dev/null || true)"
    if [[ "$mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 077) != 0 )); then
      warn "API token file permissions are broader than recommended (0600): $TOKEN_FILE mode=$mode"
    fi
    IFS= read -r API_TOKEN <"$TOKEN_FILE" || true
  fi
  if [[ -z "$API_TOKEN" && -t 0 ]]; then
    read -r -s -p "3x-ui API token: " API_TOKEN
    printf '\n' >&2
  fi
  [[ -n "$API_TOKEN" ]] || die "Set XUI_API_TOKEN, configure a token_file, or use --token-file. Use a 3x-ui API Token, not your panel password."
}

init_curl() {
  if (( INSECURE )); then
    CURL_COMMON+=(--insecure)
  fi
  CURL_COMMON+=(-H "Authorization: Bearer ${API_TOKEN}")
}

write_persistent_config() {
  local config_dir token_dest token_dir config_tmp token_tmp
  config_dir="$(dirname "$CONFIG_FILE")"
  token_dest="${TOKEN_FILE:-$config_dir/token}"
  token_dir="$(dirname "$token_dest")"

  mkdir -p "$config_dir" "$token_dir"
  chmod 700 "$config_dir" 2>/dev/null || true
  [[ ! -L "$CONFIG_FILE" ]] || die "Refusing to replace symlink config file: $CONFIG_FILE"
  [[ ! -L "$token_dest" ]] || die "Refusing to write API token through symlink: $token_dest"

  config_tmp="$(mktemp "$config_dir/.config.XXXXXX")"
  token_tmp="$(mktemp "$token_dir/.token.XXXXXX")"
  chmod 600 "$config_tmp" "$token_tmp" 2>/dev/null || true
  {
    printf 'api_base=%s\n' "$API_BASE"
    printf 'token_file=%s\n' "$token_dest"
    printf 'profile=%s\n' "$PROFILE"
    printf 'youtube=%s\n' "$YOUTUBE_MODE"
    printf 'priority=%s\n' "$PRIORITY"
    [[ -z "$DIRECT_TAG_OVERRIDE" ]] || printf 'direct_tag=%s\n' "$DIRECT_TAG_OVERRIDE"
    printf 'state_dir=%s\n' "$STATE_DIR"
    printf 'insecure=%s\n' "$INSECURE"
  } >"$config_tmp"
  printf '%s\n' "$API_TOKEN" >"$token_tmp"

  mv "$token_tmp" "$token_dest"
  mv "$config_tmp" "$CONFIG_FILE"
  chmod 600 "$token_dest" "$CONFIG_FILE" 2>/dev/null || true
  TOKEN_FILE="$token_dest"
  log "Saved persistent config: $CONFIG_FILE"
  log "Saved API token file: $TOKEN_FILE (mode 0600)"
}

api_post() {
  local path="$1"; shift
  local args=("${CURL_COMMON[@]}" -X POST)
  local kv
  for kv in "$@"; do
    args+=(--data-urlencode "$kv")
  done
  curl "${args[@]}" "${API_BASE}${path}"
}

api_get() {
  local path="$1"
  curl "${CURL_COMMON[@]}" "${API_BASE}${path}"
}

assert_success() {
  local body="$1"
  if ! jq -e '.success == true' >/dev/null 2>&1 <<<"$body"; then
    local msg
    msg="$(jq -r '.msg // .error // "3x-ui API request failed"' <<<"$body" 2>/dev/null || true)"
    [[ -n "$msg" && "$msg" != "null" ]] || msg="3x-ui API request failed"
    return 1
  fi
}

obj_json_from_body() {
  local body="$1"
  assert_success "$body" || return 1
  jq -ce '.obj | if type == "string" and length > 0 then (try fromjson catch .) else . end' <<<"$body"
}

api_post_obj_json() {
  local path="$1"; shift
  local body
  body="$(api_post "$path" "$@")" || return 1
  obj_json_from_body "$body"
}

api_get_obj_json() {
  local path="$1"
  local body
  body="$(api_get "$path")" || return 1
  obj_json_from_body "$body"
}

ensure_state_dir() {
  mkdir -p "$STATE_DIR/backups"
  chmod 700 "$STATE_DIR" "$STATE_DIR/backups" 2>/dev/null || true
}

fetch_xray_payload() {
  api_post_obj_json "/xray/"
}

configure_connection() {
  normalize_api_base
  ensure_token
  init_curl
  if ! fetch_xray_payload >/dev/null; then
    die "Cannot authenticate to 3x-ui with the supplied API base/token; nothing was saved"
  fi
  write_persistent_config
  log "Configuration verified. Future commands can run without export after reboot."
}

backup_payload() {
  local payload="$1"
  ensure_state_dir
  local ts base cfg_file meta_file
  ts="$(date -u +%Y%m%dT%H%M%SZ)-$$-${RANDOM}"
  base="$STATE_DIR/backups/${ts}"
  cfg_file="${base}.json"
  meta_file="${base}.meta.json"

  jq -e '.xraySetting' >/dev/null <<<"$payload" || die "Cannot back up: malformed Xray payload"
  jq '.xraySetting | if type == "string" then fromjson else . end' <<<"$payload" >"$cfg_file"
  jq '{createdAt:(now|todate), outboundTestUrl:(.outboundTestUrl // "https://www.google.com/generate_204")}' <<<"$payload" >"$meta_file"
  chmod 600 "$cfg_file" "$meta_file" 2>/dev/null || true
  printf '%s\n' "$cfg_file"
}

latest_backup() {
  local file
  file="$(ls -1t "$STATE_DIR"/backups/*.json 2>/dev/null | grep -v '\.meta\.json$' | head -n 1 || true)"
  [[ -n "$file" ]] || return 1
  printf '%s\n' "$file"
}

save_config_file() {
  local cfg_file="$1" test_url="$2"
  jq -e . "$cfg_file" >/dev/null || die "Refusing to save invalid JSON: $cfg_file"
  local args=("${CURL_COMMON[@]}" -X POST
    --data-urlencode "xraySetting@${cfg_file}"
    --data-urlencode "outboundTestUrl=${test_url}"
  )
  local body
  body="$(curl "${args[@]}" "${API_BASE}/xray/update")" || return 1
  assert_success "$body"
}

restore_backup_file() {
  local cfg_file="$1"
  [[ -f "$cfg_file" ]] || die "Backup not found: $cfg_file"
  local meta_file="${cfg_file%.json}.meta.json" test_url="https://www.google.com/generate_204"
  if [[ -f "$meta_file" ]]; then
    test_url="$(jq -r '.outboundTestUrl // "https://www.google.com/generate_204"' "$meta_file")"
  fi
  log "Restoring backup: $cfg_file"
  save_config_file "$cfg_file" "$test_url" || die "Rollback failed; inspect 3x-ui Xray settings manually"
  log "Rollback completed"
}

find_direct_tag() {
  local cfg_file="$1"
  if [[ -n "$DIRECT_TAG_OVERRIDE" ]]; then
    printf '%s\n' "$DIRECT_TAG_OVERRIDE"
    return
  fi
  local tag
  tag="$(jq -r '[.outbounds[]? | select(.protocol == "freedom") | .tag][0] // empty' "$cfg_file")"
  [[ -n "$tag" ]] || die "No freedom outbound found. Pass --direct-tag explicitly."
  printf '%s\n' "$tag"
}

has_warp_outbound() {
  local cfg_file="$1"
  jq -e 'any(.outbounds[]?; .tag == "warp" and .protocol == "wireguard")' "$cfg_file" >/dev/null
}

warp_account_data() {
  local data
  data="$(api_post_obj_json "/xray/warp/data")" || return 1
  if [[ "$data" == '""' || "$data" == "null" || "$data" == "{}" ]]; then
    return 2
  fi
  printf '%s\n' "$data"
}

find_xray_binary() {
  local candidate
  if [[ -n "${XRAY_BIN:-}" && -x "${XRAY_BIN}" ]]; then
    printf '%s\n' "$XRAY_BIN"
    return 0
  fi
  if command -v xray >/dev/null 2>&1; then
    command -v xray
    return 0
  fi
  for candidate in \
    /usr/local/x-ui/bin/xray \
    /usr/local/x-ui/bin/xray-linux-amd64 \
    /usr/local/x-ui/bin/xray-linux-arm64 \
    /usr/local/x-ui/bin/xray-linux-arm32 \
    /usr/local/x-ui/xray; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  while IFS= read -r candidate; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(find /usr/local/x-ui /opt/x-ui -maxdepth 3 -type f -name 'xray*' 2>/dev/null | sort)
  return 1
}

generate_keypair_with_xray() {
  local xray_bin="$1" output priv pub
  output="$("$xray_bin" wg 2>/dev/null)" || return 1
  priv="$(awk -F': ' '/^PrivateKey:/ {print $2; exit}' <<<"$output")"
  pub="$(awk -F': ' '/^Password \(PublicKey\):/ {print $2; exit}' <<<"$output")"
  [[ "$priv" =~ ^[A-Za-z0-9+/]{43}=$ ]] || return 1
  [[ "$pub" =~ ^[A-Za-z0-9+/]{43}=$ ]] || return 1
  jq -cn --arg privateKey "$priv" --arg publicKey "$pub" '{privateKey:$privateKey,publicKey:$publicKey}'
}

generate_keypair_with_wg() {
  command -v wg >/dev/null 2>&1 || return 1
  local priv pub
  priv="$(wg genkey 2>/dev/null)" || return 1
  pub="$(printf '%s' "$priv" | wg pubkey 2>/dev/null)" || return 1
  [[ -n "$priv" && -n "$pub" ]] || return 1
  jq -cn --arg privateKey "$priv" --arg publicKey "$pub" '{privateKey:$privateKey,publicKey:$publicKey}'
}

generate_wireguard_keypair() {
  local xray_bin pair
  if xray_bin="$(find_xray_binary)"; then
    if pair="$(generate_keypair_with_xray "$xray_bin")"; then
      log "Generated WARP registration keypair with Xray: $xray_bin"
      printf '%s\n' "$pair"
      return 0
    fi
    warn "Found Xray at $xray_bin, but its 'wg' key generator is unavailable; trying system wg"
  fi
  if pair="$(generate_keypair_with_wg)"; then
    log "Generated WARP registration keypair with system wg"
    printf '%s\n' "$pair"
    return 0
  fi
  cat >&2 <<'MSG'
[3xui-warp-router] ERROR: Cannot generate a WireGuard keypair for first-time WARP registration.
Tried:
  1. 3x-ui/Xray-core `xray wg`
  2. system `wg genkey` / `wg pubkey`

For Debian/Ubuntu, install the fallback tool with:
  apt update && apt install -y wireguard-tools

You can also upgrade 3x-ui/Xray-core to a version whose Xray binary supports `wg`.
MSG
  return 1
}

bytes_json_from_base64() {
  local value="$1"
  [[ -n "$value" ]] || { printf '[]\n'; return; }
  local decoded
  if ! decoded="$(printf '%s' "$value" | base64 -d 2>/dev/null | od -An -v -tu1 | awk '
    BEGIN { printf "["; first=1 }
    { for (i=1; i<=NF; i++) { if (!first) printf ","; printf "%d", $i; first=0 } }
    END { print "]" }
  ')"; then
    printf '[]\n'
    return
  fi
  [[ "$decoded" =~ ^\[[0-9,]*\]$ ]] || decoded='[]'
  printf '%s\n' "$decoded"
}

build_warp_outbound() {
  local data_json="$1" config_json="$2"
  local secret v4 v6 client_id peer_key endpoint reserved
  secret="$(jq -r '.private_key // empty' <<<"$data_json")"
  v4="$(jq -r '.config.interface.addresses.v4 // empty' <<<"$config_json")"
  v6="$(jq -r '.config.interface.addresses.v6 // empty' <<<"$config_json")"
  client_id="$(jq -r '.config.client_id // empty' <<<"$config_json")"
  [[ -n "$client_id" ]] || client_id="$(jq -r '.client_id // empty' <<<"$data_json")"
  peer_key="$(jq -r '.config.peers[0].public_key // empty' <<<"$config_json")"
  endpoint="$(jq -r '.config.peers[0].endpoint.host // empty' <<<"$config_json")"
  reserved="$(bytes_json_from_base64 "$client_id")"

  [[ -n "$secret" ]] || die "WARP data missing private_key"
  [[ -n "$peer_key" ]] || die "WARP config missing peer public_key"
  [[ -n "$endpoint" ]] || die "WARP config missing peer endpoint"
  [[ -n "$v4" || -n "$v6" ]] || die "WARP config missing interface addresses"

  jq -cn --arg secret "$secret" --arg v4 "$v4" --arg v6 "$v6" --arg peer "$peer_key" --arg endpoint "$endpoint" --argjson reserved "$reserved" '
    {
      tag:"warp", protocol:"wireguard",
      settings:{
        mtu:1420,
        secretKey:$secret,
        address:[(if $v4!="" then ($v4+"/32") else empty end),(if $v6!="" then ($v6+"/128") else empty end)],
        reserved:$reserved,
        domainStrategy:"ForceIPv4v6",
        peers:[{publicKey:$peer,endpoint:$endpoint}],
        noKernelTun:true
      }
    }'
}

ensure_warp_account_and_outbound() {
  local cfg_file="$1" data reg config outbound
  if data="$(warp_account_data)"; then
    log "Existing 3x-ui WARP account found"
    config="$(api_post_obj_json "/xray/warp/config")" || die "Cannot fetch WARP config from 3x-ui"
  else
    local rc=$?
    (( rc == 2 )) || die "Cannot query existing WARP account"
    log "No WARP account found; preparing first-time registration"
    local keypair priv pub
    keypair="$(generate_wireguard_keypair)" || die "WARP registration key generation failed"
    priv="$(jq -r '.privateKey' <<<"$keypair")"
    pub="$(jq -r '.publicKey' <<<"$keypair")"
    reg="$(api_post_obj_json "/xray/warp/reg" "privateKey=$priv" "publicKey=$pub")" || die "3x-ui WARP registration failed"
    data="$(jq -ce '.data' <<<"$reg")"
    config="$(jq -ce '.config' <<<"$reg")"
    unset keypair priv pub
  fi

  outbound="$(build_warp_outbound "$data" "$config")"
  local tmp
  tmp="$(new_tmp)"
  jq --argjson warp "$outbound" '
    .outbounds=(.outbounds//[])
    | if any(.outbounds[]?; .tag=="warp")
      then .outbounds |= map(if .tag=="warp" then (. * $warp) else . end)
      else .outbounds += [$warp]
      end' "$cfg_file" >"$tmp"
  mv "$tmp" "$cfg_file"
}

geosite_tokens_ok() {
  local csv="$1" issues

  # Prefer the 3x-ui API when available.
  if issues="$(api_post_obj_json "/xray/geodata/validate" "kind=false" "tokens=$csv" 2>/dev/null)"; then
    jq -e 'type == "array" and length == 0' >/dev/null <<<"$issues"
    return
  fi

  # Stable 3x-ui may not expose /xray/geodata/validate.
  # Validate the same tokens with the local Xray core instead.
  local xray_bin asset_dir tmp

  xray_bin="$(find_xray_binary)" || return 1
  asset_dir="${XRAY_LOCATION_ASSET:-$(dirname "$xray_bin")}"

  [[ -f "$asset_dir/geosite.dat" ]] || return 1

  tmp="$(mktemp --suffix=.json)"
  chmod 600 "$tmp" 2>/dev/null || true

  jq -n --arg csv "$csv" '
    {
      log: {loglevel: "error"},
      inbounds: [],
      outbounds: [
        {
          protocol: "freedom",
          tag: "direct"
        }
      ],
      routing: {
        domainStrategy: "AsIs",
        rules: [
          {
            type: "field",
            domain: ($csv | split(",")),
            outboundTag: "direct"
          }
        ]
      }
    }
  ' >"$tmp"

  if XRAY_LOCATION_ASSET="$asset_dir" \
    "$xray_bin" run -test -config "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    return 0
  fi

  rm -f "$tmp"
  return 1
}

json_array_from_lines() { jq -Rsc 'split("\n") | map(select(length > 0))'; }

youtube_tokens() {
  cat <<'TOKENS'
domain:youtube.com
domain:youtu.be
domain:googlevideo.com
domain:ytimg.com
domain:youtube-nocookie.com
domain:youtube.googleapis.com
domain:youtubei.googleapis.com
domain:yt.be
TOKENS
}

fallback_google_tokens() {
  cat <<'TOKENS'
domain:google.com
domain:googleapis.com
domain:gstatic.com
domain:googleusercontent.com
domain:googleadservices.com
TOKENS
}

gemini_tokens() {
  cat <<'TOKENS'
domain:gemini.google.com
domain:aistudio.google.com
domain:ai.google.dev
domain:generativelanguage.googleapis.com
domain:alkalimakersuite-pa.clients6.google.com
domain:accounts.google.com
domain:apis.google.com
domain:oauth2.googleapis.com
domain:clients6.google.com
domain:googleapis.com
domain:gstatic.com
domain:googleusercontent.com
TOKENS
}

custom_tokens() {
  [[ -n "$CUSTOM_FILE" ]] || die "profile=custom requires --custom-file"
  [[ -f "$CUSTOM_FILE" ]] || die "Custom domain file not found: $CUSTOM_FILE"
  sed -e 's/[[:space:]]*#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$CUSTOM_FILE" | awk 'NF'
}

build_managed_rules() {
  local direct_tag="$1" warp_lines="" direct_lines=""
  case "$PROFILE" in
    gemini)
      warp_lines="$(gemini_tokens)"
      if [[ "$YOUTUBE_MODE" == "direct" ]]; then direct_lines="$(youtube_tokens)"; else warp_lines+=$'\n'"$(youtube_tokens)"; fi
      ;;
    google-web)
      if geosite_tokens_ok 'geosite:google,geosite:youtube'; then
        warp_lines='geosite:google'
        if [[ "$YOUTUBE_MODE" == "direct" ]]; then direct_lines='geosite:youtube'; else warp_lines+=$'\n''geosite:youtube'; fi
      else
        warn "geosite:google/youtube unavailable or invalid; using explicit fallback domains"
        warp_lines="$(fallback_google_tokens)"
        if [[ "$YOUTUBE_MODE" == "direct" ]]; then direct_lines="$(youtube_tokens)"; else warp_lines+=$'\n'"$(youtube_tokens)"; fi
      fi
      ;;
    google-all)
      if geosite_tokens_ok 'geosite:google'; then warp_lines='geosite:google'; else warn "geosite:google unavailable or invalid; using explicit fallback domains"; warp_lines="$(fallback_google_tokens)"; fi
      warp_lines+=$'\n'"$(youtube_tokens)"
      ;;
    custom)
      warp_lines="$(custom_tokens)"
      if [[ "$YOUTUBE_MODE" == "direct" ]]; then direct_lines="$(youtube_tokens)"; else warp_lines+=$'\n'"$(youtube_tokens)"; fi
      ;;
  esac

  local warp_json direct_json
  warp_json="$(printf '%s\n' "$warp_lines" | awk 'NF && !seen[$0]++' | json_array_from_lines)"
  direct_json='[]'
  [[ -z "$direct_lines" ]] || direct_json="$(printf '%s\n' "$direct_lines" | awk 'NF && !seen[$0]++' | json_array_from_lines)"
  jq -cn \
    --arg warpTag "warp" \
    --arg directTag "$direct_tag" \
    --arg warpRuleTag "$RULE_TAG_WARP" \
    --arg directRuleTag "$RULE_TAG_DIRECT" \
    --argjson warpDomains "$warp_json" \
    --argjson directDomains "$direct_json" '
    [(if ($directDomains|length)>0 then {type:"field",ruleTag:$directRuleTag,domain:$directDomains,outboundTag:$directTag} else empty end),
      {type:"field",ruleTag:$warpRuleTag,domain:$warpDomains,outboundTag:$warpTag}]'
}

merge_managed_rules() {
  local cfg_file="$1" managed_rules="$2" tmp
  tmp="$(new_tmp)"
  jq \
    --arg markerWarp "$MARKER_WARP" \
    --arg markerDirect "$MARKER_DIRECT" \
    --arg ruleTagWarp "$RULE_TAG_WARP" \
    --arg ruleTagDirect "$RULE_TAG_DIRECT" \
    --arg priority "$PRIORITY" \
    --argjson managed "$managed_rules" '
    .routing=(.routing//{}) | .routing.rules=(.routing.rules//[])
    | .routing.rules |= map(select(
        ((.ruleTag//"") != $ruleTagWarp)
        and ((.ruleTag//"") != $ruleTagDirect)
        and (((.domain//[])|index($markerWarp))==null)
        and (((.domain//[])|index($markerDirect))==null)
      ))
    | if $priority=="prepend" then .routing.rules=($managed+.routing.rules) else .routing.rules=(.routing.rules+$managed) end' "$cfg_file" >"$tmp"
  mv "$tmp" "$cfg_file"
}

remove_managed_rules_from_file() {
  local cfg_file="$1" tmp
  tmp="$(new_tmp)"
  jq \
    --arg markerWarp "$MARKER_WARP" \
    --arg markerDirect "$MARKER_DIRECT" \
    --arg ruleTagWarp "$RULE_TAG_WARP" \
    --arg ruleTagDirect "$RULE_TAG_DIRECT" '
    if (.routing.rules?|type)=="array" then
      .routing.rules |= map(select(
        ((.ruleTag//"") != $ruleTagWarp)
        and ((.ruleTag//"") != $ruleTagDirect)
        and (((.domain//[])|index($markerWarp))==null)
        and (((.domain//[])|index($markerDirect))==null)
      ))
    else . end' "$cfg_file" >"$tmp"
  mv "$tmp" "$cfg_file"
}

managed_state_summary() {
  local cfg_file="$1"
  jq -r \
    --arg mw "$MARKER_WARP" \
    --arg md "$MARKER_DIRECT" \
    --arg rw "$RULE_TAG_WARP" \
    --arg rd "$RULE_TAG_DIRECT" '
    def managed($m; $r): [.routing.rules[]? | select((.ruleTag//"")==$r or (((.domain//[])|index($m))!=null))];
    "warp_outbound="+(if any(.outbounds[]?;.tag=="warp" and .protocol=="wireguard") then "present" else "missing" end),
    "warp_rule_count="+((managed($mw; $rw)|length)|tostring),
    "direct_rule_count="+((managed($md; $rd)|length)|tostring),
    "warp_endpoint="+([.outbounds[]?|select(.tag=="warp")|.settings.peers[0].endpoint][0]//"n/a"),
    "warp_noKernelTun="+(([.outbounds[]?|select(.tag=="warp")|.settings.noKernelTun][0]//false)|tostring)' "$cfg_file"
}

inbound_sniffing_records() {
  local cfg_file="$1"
  jq -r '
    (.inbounds // [])
    | if type == "array" then . else [] end
    | to_entries[]
    | select((.value.tag // "") != "api")
    | [
        (.value.tag // ("inbound-" + (.key | tostring))),
        (if ((.value.sniffing // {}).enabled == true) then "enabled" else "disabled" end)
      ]
    | @tsv
  ' "$cfg_file"
}

check_inbound_sniffing() {
  local cfg_file="$1" mode="${2:-warning}" tag state
  local checked=0 disabled=0

  while IFS=$'\t' read -r tag state; do
    [[ -n "$tag" ]] || continue
    checked=$((checked + 1))
    [[ "$state" == "enabled" ]] || {
      disabled=$((disabled + 1))
      if [[ "$mode" == "test" || "$mode" == "diagnose" ]]; then
        diag_line WARN "Inbound sniffing" "$tag disabled"
      else
        warn "inbound $tag has sniffing disabled."
      fi
    }
  done < <(inbound_sniffing_records "$cfg_file")

  if (( checked == 0 )); then
    if [[ "$mode" == "test" || "$mode" == "diagnose" ]]; then
      diag_line WARN "Inbound sniffing" "no client inbounds found"
    else
      warn "No client inbounds found; domain-based WARP routing cannot be verified."
    fi
    return 1
  fi

  if (( disabled > 0 )); then
    if [[ "$mode" == "test" || "$mode" == "diagnose" ]]; then
      diag_line WARN "Domain routing" "may not work when clients send resolved IP addresses"
    else
      warn "Domain-based WARP routing may not work when clients send resolved IP addresses."
    fi
    return 1
  fi

  if [[ "$mode" == "test" || "$mode" == "diagnose" ]]; then
    diag_line OK "Inbound sniffing" "enabled on ${checked} client inbound(s)"
  fi
  return 0
}

route_decision_json() {
  local domain="$1" result
  result="$(api_post_obj_json "/xray/routeTest" "domain=$domain" "port=443" "network=tcp")" || return 1
  if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$result"; then
    warn "3x-ui routeTest returned invalid JSON"
    return 1
  fi
  printf '%s\n' "$result"
}

route_test() {
  local domain="$1" expected="$2" result matched tag
  result="$(route_decision_json "$domain")" || return 1
  matched="$(jq -r '.matched // false' <<<"$result")"
  tag="$(jq -r '.outboundTag // empty' <<<"$result")"
  printf '%-28s -> %s%s\n' "$domain" "${tag:-<default>}" "${expected:+ (expected: $expected)}"
  [[ "$matched" == "true" && "$tag" == "$expected" ]]
}

outbound_probe_json() {
  local cfg_file="$1" mode="${2:-real}" warp all
  warp="$(jq -c '.outbounds[]? | select(.tag=="warp")' "$cfg_file" | head -n 1)"
  [[ -n "$warp" ]] || return 1
  all="$(jq -c '.outbounds//[]' "$cfg_file")"
  api_post_obj_json "/xray/testOutbound" "outbound=$warp" "allOutbounds=$all" "mode=$mode"
}

outbound_test() {
  local cfg_file="$1" result egress_country egress_warp
  result="$(outbound_probe_json "$cfg_file")" || return 1
  printf 'WARP outbound test: %s\n' "$(jq -c . <<<"$result")"
  if ! jq -e 'if type!="object" then false elif has("success") then .success==true else ((.error? // "")=="") end' >/dev/null <<<"$result"; then return 1; fi
  egress_country="$(jq -r '.egress.country // empty' <<<"$result")"
  egress_warp="$(jq -r '.egress.warp // empty' <<<"$result")"
  [[ "$egress_warp" != "off" ]] || { warn "Outbound probe reached the Internet but Cloudflare trace reports warp=off"; return 1; }
  [[ "$egress_country" != "CN" ]] || { warn "WARP egress country is CN; this does not satisfy the anti-misclassification goal"; return 1; }
}

wait_for_route_api() {
  local i
  for i in {1..15}; do
    if route_decision_json 'gemini.google.com' >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  return 1
}

post_apply_test() {
  local cfg_file="$1" direct_tag="$2" ok=0
  wait_for_route_api || { warn "Xray route API did not become ready"; return 1; }
  case "$PROFILE" in
    gemini) route_test 'gemini.google.com' 'warp' || ok=1 ;;
    google-web) route_test 'www.google.com' 'warp' || ok=1 ;;
    google-all) route_test 'www.google.com' 'warp' || ok=1; route_test 'www.youtube.com' 'warp' || ok=1 ;;
    custom) ;;
  esac
  if [[ "$YOUTUBE_MODE" == "direct" && "$PROFILE" != "google-all" ]]; then
    local result tag
    if ! result="$(route_decision_json 'www.youtube.com')"; then
      ok=1
      result='{}'
    fi
    tag="$(jq -r '.outboundTag // empty' <<<"$result")"
    printf '%-28s -> %s (expected direct/default)\n' 'www.youtube.com' "${tag:-<default>}"
    [[ -z "$tag" || "$tag" == "$direct_tag" ]] || ok=1
  elif [[ "$YOUTUBE_MODE" == "warp" && "$PROFILE" != "google-all" ]]; then
    route_test 'www.youtube.com' 'warp' || ok=1
  fi
  outbound_test "$cfg_file" || ok=1
  return "$ok"
}

apply_routes() {
  local allow_bootstrap="$1" payload cfg_file backup_file test_url direct_tag managed
  payload="$(fetch_xray_payload)" || die "Cannot read Xray settings. Check API URL/token."
  cfg_file="$(new_tmp)"
  jq '.xraySetting | if type=="string" then fromjson else . end' <<<"$payload" >"$cfg_file"
  test_url="$(jq -r '.outboundTestUrl // "https://www.google.com/generate_204"' <<<"$payload")"
  backup_file="$(backup_payload "$payload")"
  log "Backup: $backup_file"

  if ! has_warp_outbound "$cfg_file"; then
    if [[ "$allow_bootstrap" == "yes" ]]; then ensure_warp_account_and_outbound "$cfg_file"; else die "No native 3x-ui WARP WireGuard outbound tagged 'warp'. Run '$SCRIPT_NAME bootstrap' or '$SCRIPT_NAME install'."; fi
  fi

  check_inbound_sniffing "$cfg_file" apply || true
  direct_tag="$(find_direct_tag "$cfg_file")"
  managed="$(build_managed_rules "$direct_tag")"
  merge_managed_rules "$cfg_file" "$managed"
  jq -e . "$cfg_file" >/dev/null || die "Generated config is not valid JSON"
  log "Applying profile=$PROFILE youtube=$YOUTUBE_MODE priority=$PRIORITY directTag=$direct_tag"
  if ! save_config_file "$cfg_file" "$test_url"; then
    warn "3x-ui rejected the config or failed to reload Xray"
    (( AUTO_ROLLBACK )) && restore_backup_file "$backup_file"
    return 1
  fi

  local refreshed refreshed_cfg
  refreshed="$(fetch_xray_payload)" || true
  refreshed_cfg="$(new_tmp)"
  if [[ -n "$refreshed" ]]; then jq '.xraySetting | if type=="string" then fromjson else . end' <<<"$refreshed" >"$refreshed_cfg"; else cp "$cfg_file" "$refreshed_cfg"; fi
  if ! post_apply_test "$refreshed_cfg" "$direct_tag"; then
    warn "Post-apply verification failed"
    if (( AUTO_ROLLBACK )); then restore_backup_file "$backup_file"; return 1; fi
  fi
  log "Applied successfully"
}

bootstrap_only() {
  local payload cfg_file backup_file test_url
  payload="$(fetch_xray_payload)" || die "Cannot read Xray settings"
  cfg_file="$(new_tmp)"
  jq '.xraySetting | if type=="string" then fromjson else . end' <<<"$payload" >"$cfg_file"
  test_url="$(jq -r '.outboundTestUrl // "https://www.google.com/generate_204"' <<<"$payload")"
  backup_file="$(backup_payload "$payload")"
  log "Backup: $backup_file"
  ensure_warp_account_and_outbound "$cfg_file"
  save_config_file "$cfg_file" "$test_url" || { warn "Failed to save WARP outbound"; (( AUTO_ROLLBACK )) && restore_backup_file "$backup_file"; return 1; }
  outbound_test "$cfg_file" || { warn "WARP outbound was created but connectivity test failed"; (( AUTO_ROLLBACK )) && restore_backup_file "$backup_file"; return 1; }
  log "Native 3x-ui WARP outbound is ready"
}

remove_routes() {
  local payload cfg_file backup_file test_url
  payload="$(fetch_xray_payload)" || die "Cannot read Xray settings"
  cfg_file="$(new_tmp)"
  jq '.xraySetting | if type=="string" then fromjson else . end' <<<"$payload" >"$cfg_file"
  test_url="$(jq -r '.outboundTestUrl // "https://www.google.com/generate_204"' <<<"$payload")"
  backup_file="$(backup_payload "$payload")"
  log "Backup: $backup_file"
  remove_managed_rules_from_file "$cfg_file"
  save_config_file "$cfg_file" "$test_url" || { warn "Failed to remove managed rules"; (( AUTO_ROLLBACK )) && restore_backup_file "$backup_file"; return 1; }
  log "Managed routing rules removed; WARP account/outbound left untouched"
}

get_rotate_interval() {
  local settings
  settings="$(api_post_obj_json "/setting/all" 2>/dev/null)" || return 1
  jq -r '.warpUpdateInterval // 0' <<<"$settings"
}

show_rotate_interval() {
  local days
  if days="$(get_rotate_interval)"; then
    if [[ "$days" =~ ^[0-9]+$ ]] && (( days > 0 )); then printf 'warp_auto_rotation_days=%s\n' "$days"; else printf 'warp_auto_rotation_days=0 (disabled)\n'; fi
  else
    printf 'warp_auto_rotation_days=unknown\n'
  fi
}

set_rotate_interval() {
  local days="$1"
  [[ "$days" =~ ^[0-9]+$ ]] || die "--rotate-days must be a non-negative integer"
  api_post_obj_json "/xray/warp/interval" "interval=$days" >/dev/null || die "Failed to set WARP rotation interval"
  if (( days == 0 )); then log "WARP auto-rotation disabled"; else log "WARP auto-rotation interval set to ${days} day(s)"; fi
}

show_status() {
  local payload cfg_file
  payload="$(fetch_xray_payload)" || die "Cannot read Xray settings"
  cfg_file="$(new_tmp)"
  jq '.xraySetting | if type=="string" then fromjson else . end' <<<"$payload" >"$cfg_file"
  managed_state_summary "$cfg_file"
  printf '\nManaged rules:\n'
  jq -r \
    --arg mw "$MARKER_WARP" \
    --arg md "$MARKER_DIRECT" \
    --arg rw "$RULE_TAG_WARP" \
    --arg rd "$RULE_TAG_DIRECT" '
    .routing.rules[]?
    | select((.ruleTag//"")==$rw or (.ruleTag//"")==$rd or (((.domain//[])|index($mw))!=null) or (((.domain//[])|index($md))!=null))
    | "- "+(.outboundTag//"")+": "+((.domain//[]) | map(select(. != $mw and . != $md)) | join(", "))' "$cfg_file"
  printf '\n3x-ui WARP rotation:\n'
  show_rotate_interval
}

managed_domains_json() {
  local cfg_file="$1" marker="$2" rule_tag
  if [[ "$marker" == "$MARKER_WARP" ]]; then
    rule_tag="$RULE_TAG_WARP"
  else
    rule_tag="$RULE_TAG_DIRECT"
  fi
  jq -c --arg m "$marker" --arg rt "$rule_tag" '
    [.routing.rules[]?
     | select((.ruleTag//"")==$rt or (((.domain//[])|index($m))!=null))
     | (.domain//[])[]
     | select(. != $m)]' "$cfg_file"
}

domain_expected_warp() {
  local cfg_file="$1" kind="$2" domains
  domains="$(managed_domains_json "$cfg_file" "$MARKER_WARP")"
  case "$kind" in
    google)
      jq -e 'any(.[]; .=="geosite:google" or .=="domain:google.com" or .=="full:www.google.com")' >/dev/null <<<"$domains"
      ;;
    gemini)
      jq -e 'any(.[]; .=="geosite:google" or .=="domain:google.com" or .=="domain:gemini.google.com" or .=="full:gemini.google.com")' >/dev/null <<<"$domains"
      ;;
    youtube)
      jq -e 'any(.[]; .=="geosite:youtube" or test("youtube|youtu\\.be|googlevideo|ytimg|yt\\.be"))' >/dev/null <<<"$domains"
      ;;
  esac
}

domain_expected_direct() {
  local cfg_file="$1" kind="$2" domains
  domains="$(managed_domains_json "$cfg_file" "$MARKER_DIRECT")"
  case "$kind" in
    youtube) jq -e 'any(.[]; .=="geosite:youtube" or test("youtube|youtu\\.be|googlevideo|ytimg|yt\\.be"))' >/dev/null <<<"$domains" ;;
    *) return 1 ;;
  esac
}

test_current() {
  local payload cfg_file direct_tag ok=0 warnings=0 result tag
  payload="$(fetch_xray_payload)" || die "Cannot read Xray settings"
  cfg_file="$(new_tmp)"
  jq '.xraySetting | if type=="string" then fromjson else . end' <<<"$payload" >"$cfg_file"
  has_warp_outbound "$cfg_file" || die "WARP outbound missing"
  direct_tag="$(find_direct_tag "$cfg_file")"

  if ! check_inbound_sniffing "$cfg_file" test; then warnings=$((warnings + 1)); fi
  if domain_expected_warp "$cfg_file" google; then route_test 'www.google.com' 'warp' || ok=1; fi
  if domain_expected_warp "$cfg_file" gemini; then route_test 'gemini.google.com' 'warp' || ok=1; fi
  if domain_expected_warp "$cfg_file" youtube; then
    route_test 'www.youtube.com' 'warp' || ok=1
  elif domain_expected_direct "$cfg_file" youtube; then
    if ! result="$(route_decision_json 'www.youtube.com')"; then
      ok=1
      result='{}'
    fi
    tag="$(jq -r '.outboundTag // empty' <<<"$result")"
    printf '%-28s -> %s (expected direct/default)\n' 'www.youtube.com' "${tag:-<default>}"
    [[ -z "$tag" || "$tag" == "$direct_tag" ]] || ok=1
  fi
  outbound_test "$cfg_file" || ok=1
  (( ok == 0 )) || die "One or more tests failed"
  if (( warnings > 0 )); then
    warn "Tests passed with warning(s); domain-based WARP routing is not guaranteed for every client inbound"
  else
    log "Tests passed"
  fi
}

rotate_warp() {
  local result warning
  result="$(api_post_obj_json "/xray/warp/changeIp")" || die "WARP IP rotation failed"
  warning="$(jq -r '.warning // empty' <<<"$result")"
  [[ -z "$warning" ]] || warn "$warning"
  log "3x-ui rotated the WARP registration/IP and updated the warp outbound"
  sleep 1
  test_current
}

manage_rotation() {
  [[ -z "$ROTATE_DAYS" ]] || set_rotate_interval "$ROTATE_DAYS"
  show_rotate_interval
}

diag_line() {
  local level="$1" label="$2" value="$3"
  printf '[%-4s] %-24s %s\n' "$level" "$label" "$value"
}

diagnose_route() {
  local cfg_file="$1" label="$2" domain="$3" expected="$4" direct_tag="${5:-}" result matched tag actual
  if ! result="$(route_decision_json "$domain")"; then
    diag_line FAIL "$label route" "routeTest API failed"
    return 1
  fi
  matched="$(jq -r '.matched // false' <<<"$result")"
  tag="$(jq -r '.outboundTag // empty' <<<"$result")"
  actual="${tag:-<default>}"
  if [[ -z "$expected" ]]; then
    diag_line INFO "$label route" "$domain -> $actual"
    return 0
  fi
  if [[ "$expected" == "direct" ]]; then
    if [[ -z "$tag" || ( -n "$direct_tag" && "$tag" == "$direct_tag" ) ]]; then
      diag_line OK "$label route" "$domain -> $actual (expected direct/default)"
      return 0
    fi
  elif [[ "$matched" == "true" && "$tag" == "$expected" ]]; then
    diag_line OK "$label route" "$domain -> $actual"
    return 0
  fi
  diag_line FAIL "$label route" "$domain -> $actual (expected $expected)"
  return 1
}

diagnose() {
  local issues=0 warnings=0 payload cfg_file probe probe_ok=0 direct_tag="" days="" expected
  printf '========================================\n'
  printf '3xui-warp-router diagnosis v%s\n' "$VERSION"
  printf '========================================\n\n'

  if ! payload="$(fetch_xray_payload)"; then
    diag_line FAIL "3x-ui API" "authentication/request failed"
    printf '\nConclusion:\n  FAIL - Cannot read 3x-ui Xray settings. Check API base/token and panel reachability.\n'
    return 1
  fi
  diag_line OK "3x-ui API" "reachable and authenticated"

  cfg_file="$(new_tmp)"
  if ! jq '.xraySetting | if type=="string" then fromjson else . end' <<<"$payload" >"$cfg_file" || ! jq -e . "$cfg_file" >/dev/null; then
    diag_line FAIL "Xray config" "invalid or unreadable JSON"
    printf '\nConclusion:\n  FAIL - 3x-ui returned an invalid Xray configuration.\n'
    return 1
  fi
  diag_line OK "Xray config" "valid JSON"

  if ! check_inbound_sniffing "$cfg_file" diagnose; then warnings=$((warnings + 1)); fi

  if route_decision_json 'www.google.com' >/dev/null 2>&1; then diag_line OK "Xray route API" "responsive"; else diag_line FAIL "Xray route API" "not responsive"; issues=$((issues+1)); fi

  if has_warp_outbound "$cfg_file"; then
    diag_line OK "WARP outbound" "present (wireguard)"
    local endpoint no_kernel
    endpoint="$(jq -r '[.outbounds[]?|select(.tag=="warp")|.settings.peers[0].endpoint][0] // "n/a"' "$cfg_file")"
    no_kernel="$(jq -r '[.outbounds[]?|select(.tag=="warp")|.settings.noKernelTun][0] // false' "$cfg_file")"
    diag_line INFO "WARP endpoint" "$endpoint"
    if [[ "$no_kernel" == "true" ]]; then diag_line OK "WARP userspace" "noKernelTun=true"; else diag_line WARN "WARP userspace" "noKernelTun is not true"; warnings=$((warnings+1)); fi
  else
    diag_line FAIL "WARP outbound" "missing"
    issues=$((issues+1))
  fi

  if has_warp_outbound "$cfg_file" && probe="$(outbound_probe_json "$cfg_file" http 2>/dev/null)"; then
    local success ipv4 ipv6 country warp_state delay error
    success="$(jq -r 'if has("success") then .success else ((.error? // "")=="") end' <<<"$probe")"
    ipv4="$(jq -r '.egress.ipv4 // .egress.ip // empty' <<<"$probe")"
    ipv6="$(jq -r '.egress.ipv6 // empty' <<<"$probe")"
    country="$(jq -r '.egress.country // empty' <<<"$probe")"
    warp_state="$(jq -r '.egress.warp // empty' <<<"$probe")"
    delay="$(jq -r '.delay // empty' <<<"$probe")"
    error="$(jq -r '.error // empty' <<<"$probe")"
    if [[ "$success" == "true" ]]; then diag_line OK "WARP connectivity" "success${delay:+, delay=${delay}}"; probe_ok=1; else diag_line FAIL "WARP connectivity" "${error:-probe failed}"; issues=$((issues+1)); fi
    diag_line INFO "WARP egress IPv4" "${ipv4:-unknown}"
    [[ -z "$ipv6" ]] || diag_line INFO "WARP egress IPv6" "$ipv6"
    diag_line INFO "WARP egress country" "${country:-unknown}"
    diag_line INFO "Cloudflare WARP" "${warp_state:-unknown}"
    if [[ "$warp_state" == "off" ]]; then diag_line FAIL "WARP trace check" "warp=off"; issues=$((issues+1)); fi
    if [[ "$country" == "CN" ]]; then diag_line FAIL "WARP country check" "country=CN"; issues=$((issues+1)); fi
  elif has_warp_outbound "$cfg_file"; then
    diag_line FAIL "WARP connectivity" "outbound probe API failed"
    issues=$((issues+1))
  fi

  direct_tag="$(jq -r '[.outbounds[]?|select(.protocol=="freedom")|.tag][0] // empty' "$cfg_file")"
  [[ -n "$direct_tag" ]] && diag_line OK "Direct outbound" "$direct_tag" || { diag_line WARN "Direct outbound" "freedom outbound not found"; warnings=$((warnings+1)); }

  expected=""
  domain_expected_warp "$cfg_file" google && expected="warp"
  diagnose_route "$cfg_file" "Google" 'www.google.com' "$expected" || issues=$((issues+1))

  expected=""
  domain_expected_warp "$cfg_file" gemini && expected="warp"
  diagnose_route "$cfg_file" "Gemini" 'gemini.google.com' "$expected" || issues=$((issues+1))

  expected=""
  if domain_expected_warp "$cfg_file" youtube; then expected="warp"; elif domain_expected_direct "$cfg_file" youtube; then expected="direct"; fi
  diagnose_route "$cfg_file" "YouTube" 'www.youtube.com' "$expected" "$direct_tag" || issues=$((issues+1))

  if days="$(get_rotate_interval)"; then
    if [[ "$days" =~ ^[0-9]+$ ]] && (( days > 0 )); then diag_line INFO "WARP auto-rotation" "every ${days} day(s)"; else diag_line INFO "WARP auto-rotation" "disabled"; fi
  else
    diag_line WARN "WARP auto-rotation" "unable to read setting"
    warnings=$((warnings+1))
  fi

  local managed_warp_count managed_direct_count
  managed_warp_count="$(jq \
    --arg m "$MARKER_WARP" \
    --arg r "$RULE_TAG_WARP" \
    '[.routing.rules[]? | select((.ruleTag//"")==$r or (((.domain//[])|index($m))!=null))] | length' "$cfg_file")"
  managed_direct_count="$(jq \
    --arg m "$MARKER_DIRECT" \
    --arg r "$RULE_TAG_DIRECT" \
    '[.routing.rules[]? | select((.ruleTag//"")==$r or (((.domain//[])|index($m))!=null))] | length' "$cfg_file")"
  diag_line INFO "Managed rules" "warp=${managed_warp_count}, direct=${managed_direct_count}"
  if (( managed_warp_count == 0 )); then diag_line WARN "Managed routing" "no xui-warp-router WARP rule found"; warnings=$((warnings+1)); fi

  printf '\nConclusion:\n'
  if (( issues > 0 )); then
    printf '  FAIL - %d blocking issue(s), %d warning(s).\n' "$issues" "$warnings"
    if (( probe_ok == 0 )); then printf '  Action: fix WARP outbound connectivity first, then run diagnose again.\n'; else printf '  Action: inspect the FAIL route/config lines above; WARP itself is reachable.\n'; fi
    return 1
  fi
  if (( warnings > 0 )); then
    printf '  OK with warnings - WARP/routing checks passed; review %d warning(s).\n' "$warnings"
  else
    printf '  OK - Xray, WARP, managed routing, and rotation checks are healthy.\n'
  fi
  printf '  Recommendation: keep the current WARP IP while Google/Gemini work normally.\n'
}

list_backups() {
  ensure_state_dir
  find "$STATE_DIR/backups" -maxdepth 1 -type f -name '*.json' ! -name '*.meta.json' -print 2>/dev/null | sort || true
}

parse_args() {
  (($# > 0)) || { usage; exit 2; }
  COMMAND="$1"; shift
  while (($#)); do
    case "$1" in
      --api-base) [[ $# -ge 2 ]] || die "--api-base requires a value"; API_BASE="$2"; shift 2 ;;
      --token-file) [[ $# -ge 2 ]] || die "--token-file requires a value"; TOKEN_FILE="$2"; shift 2 ;;
      --config) [[ $# -ge 2 ]] || die "--config requires a value"; CONFIG_FILE="$2"; shift 2 ;;
      --no-config) CONFIG_DISABLED=1; shift ;;
      --profile) [[ $# -ge 2 ]] || die "--profile requires a value"; PROFILE="$2"; shift 2 ;;
      --youtube) [[ $# -ge 2 ]] || die "--youtube requires a value"; YOUTUBE_MODE="$2"; shift 2 ;;
      --custom-file) [[ $# -ge 2 ]] || die "--custom-file requires a value"; CUSTOM_FILE="$2"; shift 2 ;;
      --priority) [[ $# -ge 2 ]] || die "--priority requires a value"; PRIORITY="$2"; shift 2 ;;
      --direct-tag) [[ $# -ge 2 ]] || die "--direct-tag requires a value"; DIRECT_TAG_OVERRIDE="$2"; shift 2 ;;
      --rotate-days) [[ $# -ge 2 ]] || die "--rotate-days requires a value"; ROTATE_DAYS="$2"; shift 2 ;;
      --state-dir) [[ $# -ge 2 ]] || die "--state-dir requires a value"; STATE_DIR="$2"; shift 2 ;;
      --insecure) INSECURE=1; shift ;;
      --no-auto-rollback) AUTO_ROLLBACK=0; shift ;;
      -h|--help) usage; exit 0 ;;
      --version) printf '%s\n' "$VERSION"; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
}

main() {
  (($# > 0)) || { usage; exit 2; }
  case "$1" in help|-h|--help) usage; return 0 ;; --version) printf '%s\n' "$VERSION"; return 0 ;; esac

  preparse_config_args "$@"
  load_config_file
  parse_args "$@"
  finalize_defaults
  validate_options

  need_cmd curl
  need_cmd jq

  if [[ "$COMMAND" == "configure" ]]; then
    ensure_state_dir
    init_run_tmpdir
    configure_connection
    return 0
  fi

  need_cmd base64
  need_cmd od
  normalize_api_base
  ensure_token
  init_curl
  ensure_state_dir
  init_run_tmpdir

  case "$COMMAND" in
    install) apply_routes yes; [[ -z "$ROTATE_DAYS" ]] || set_rotate_interval "$ROTATE_DAYS" ;;
    bootstrap) bootstrap_only; [[ -z "$ROTATE_DAYS" ]] || set_rotate_interval "$ROTATE_DAYS" ;;
    apply) apply_routes no; [[ -z "$ROTATE_DAYS" ]] || set_rotate_interval "$ROTATE_DAYS" ;;
    status) show_status ;;
    test) test_current ;;
    diagnose) diagnose ;;
    rotate) rotate_warp ;;
    rotation) manage_rotation ;;
    remove) remove_routes ;;
    rollback) local b; b="$(latest_backup)" || die "No backups found in $STATE_DIR/backups"; restore_backup_file "$b" ;;
    backups) list_backups ;;
    help) usage ;;
    *) die "Unknown command: $COMMAND" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
