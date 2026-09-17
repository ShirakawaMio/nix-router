#!/usr/bin/env bash
set -euo pipefail

MY_ROUTER_CONFIG_DIR="${MY_ROUTER_CONFIG_DIR:-/etc/my-router}"
MY_ROUTER_ENV="${MY_ROUTER_ENV:-$MY_ROUTER_CONFIG_DIR/miople.env}"
MY_ROUTER_STATE_DIR="${MY_ROUTER_STATE_DIR:-/var/lib/my-router}"
MY_ROUTER_WWW_DIR="${MY_ROUTER_WWW_DIR:-$MY_ROUTER_STATE_DIR/www}"
WIREGUARD_DIR="${WIREGUARD_DIR:-/etc/wireguard}"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '==> %s\n' "$*"
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 && "${MY_ROUTER_ALLOW_NON_ROOT:-0}" != "1" ]]; then
    die "run as root"
  fi
}

load_env() {
  if [[ ! -f "$MY_ROUTER_ENV" ]]; then
    die "missing $MY_ROUTER_ENV; start from hosts/miople/miople.env.example"
  fi

  set -a
  # shellcheck source=/dev/null
  source "$MY_ROUTER_ENV"
  set +a

  MY_ROUTER_CONFIG_DIR="${MY_ROUTER_CONFIG_DIR:-/etc/my-router}"
  MY_ROUTER_STATE_DIR="${MY_ROUTER_STATE_DIR:-/var/lib/my-router}"
  MY_ROUTER_WWW_DIR="${MY_ROUTER_WWW_DIR:-$MY_ROUTER_STATE_DIR/www}"
  WIREGUARD_DIR="${WIREGUARD_DIR:-/etc/wireguard}"
}

script_dir() {
  CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[1]}")" && pwd
}

package_root() {
  local dir
  dir="$(script_dir)"
  readlink -f "$dir/.."
}

share_dir() {
  if [[ -n "${MY_ROUTER_SHARE:-}" && -d "$MY_ROUTER_SHARE" ]]; then
    printf '%s\n' "$MY_ROUTER_SHARE"
  else
    local root
    root="$(package_root)"
    if [[ -d "$root/share/my-router" ]]; then
      printf '%s\n' "$root/share/my-router"
    else
      printf '%s\n' "$root"
    fi
  fi
}

comma_to_space() {
  printf '%s\n' "${1:-}" | tr ',' ' ' | xargs
}

nft_set() {
  local values
  values="$(comma_to_space "${1:-}")"
  if [[ -z "$values" ]]; then
    printf '{}'
    return
  fi

  local first=1
  printf '{ '
  for value in $values; do
    if [[ "$first" -eq 0 ]]; then
      printf ', '
    fi
    first=0
    printf '%s' "$value"
  done
  printf ' }'
}

require_file() {
  local path="$1"
  local label="$2"
  [[ -f "$path" ]] || die "missing $label at $path"
}
