#!/usr/bin/env bash
# Print the current DSH URLs. The ?token= rotates on every restart, so open one
# of these once per address to mint the browser cookie for that address.
# Addresses come from the machine's own interface list: nothing here needs
# Tailscale or any other specific network.
set -uo pipefail

PORT="${DSH_TARGET_PORT:-3080}"
GO_PORT="${DSH_GO_PORT:-3081}"

LINE="$(journalctl --user -u dsh-web.service -n 200 --no-pager 2>/dev/null \
  | grep -o "http://127\.0\.0\.1:${PORT}/?token=[^ )]*" | tail -n 1 || true)"
if [ -z "$LINE" ]; then
  echo "dsh-url: no startup URL in logs yet. Check: journalctl --user -u dsh-web -n 50"
  exit 1
fi
TOKEN="$(printf '%s' "$LINE" | sed 's/.*token=//')"

echo "local:     $LINE"
ADDRESSES="$(hostname -I 2>/dev/null || true)"
if [ -z "$ADDRESSES" ]; then
  ADDRESSES="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)"
fi
for ip in $ADDRESSES; do
  case "$ip" in
    127.*) continue ;;
  esac
  echo "address:   http://$ip:$PORT/?token=$TOKEN"
done
echo "bookmark:  http://<one of the addresses above>:$GO_PORT/   (dsh-go mints the cookie)"
