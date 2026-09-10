#!/usr/bin/env bash
# Print the current DSH URLs (token rotates on every restart).
# Visit the tailscale URL once after each restart to mint the browser cookie.
set -uo pipefail
LINE="$(journalctl --user -u dsh-web.service -n 100 --no-pager 2>/dev/null | grep -o 'http://127\.0\.0\.1:3080/?token=[^ )]*' | tail -n 1 || true)"
if [ -z "$LINE" ]; then
  echo "dsh-url: no startup URL in logs yet. Check: journalctl --user -u dsh-web.service -n 50"
  exit 1
fi
TOKEN="${LINE##*token=}"
TIP="$(tailscale ip -4 2>/dev/null | head -n 1 || true)"
echo "local:     $LINE"
if [ -n "$TIP" ]; then
  echo "tailscale: http://$TIP:3080/?token=$TOKEN"
fi
echo "magicdns:  http://kamer.tail39c8ca.ts.net:3080/?token=$TOKEN"
