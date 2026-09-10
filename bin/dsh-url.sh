#!/usr/bin/env bash
# Print the current DSH URLs. The ?token= rotates on every restart, so open one
# of these once per address to mint the browser cookie for that address.
# Addresses come from the machine's own interface list -- no Tailscale or other
# network-specific discovery -- and container bridges are skipped because they
# are not reachable from other machines.
set -uo pipefail

# The checkout is found through the script itself, not through the path it was
# called by: dsh-update and friends are symlinks in ~/.local/bin.
SELF="${BASH_SOURCE[0]}"
if command -v readlink >/dev/null 2>&1; then
  SELF="$(readlink -f "$SELF" 2>/dev/null || printf '%s' "$SELF")"
fi
OPS="$(cd "$(dirname "$SELF")/.." && pwd)"
# Ports follow dsh-ops.conf when the checkout has one; the environment wins.
DSH_PORT=3080
DSH_GO_PORT=3081
if [ -f "$OPS/dsh-ops.conf" ]; then
  # shellcheck disable=SC1090 -- operator-owned file beside this checkout
  . "$OPS/dsh-ops.conf"
fi
PORT="${DSH_TARGET_PORT:-${DSH_PORT:-3080}}"
GO_PORT="${DSH_GO_PORT:-3081}"

LINE="$(journalctl --user -u dsh-web.service -n 200 --no-pager 2>/dev/null \
  | grep -o "http://127\.0\.0\.1:${PORT}/?token=[^ )]*" | tail -n 1 || true)"
if [ -z "$LINE" ]; then
  echo "dsh-url: no startup URL in logs yet. Check: journalctl --user -u dsh-web -n 50"
  exit 1
fi
TOKEN="$(printf '%s' "$LINE" | sed 's/.*token=//')"

echo "local:      $LINE"

print_address() {
  echo "address:    http://$1:$PORT/?token=$TOKEN   ($2)"
}

if command -v ip >/dev/null 2>&1; then
  ip -4 -o addr show scope global 2>/dev/null | while read -r _ ifname _ addr _; do
    case "$ifname" in
      lo|docker*|br-*|veth*|virbr*) continue ;;
    esac
    print_address "$(printf '%s' "$addr" | cut -d/ -f1)" "$ifname"
  done
else
  for ip_addr in $(hostname -I 2>/dev/null || true); do
    case "$ip_addr" in
      127.*) continue ;;
    esac
    print_address "$ip_addr" "interface"
  done
fi

echo "bookmark:   http://<one of the addresses above>:$GO_PORT/   (dsh-go mints the cookie)"
