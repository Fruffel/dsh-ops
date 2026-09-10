#!/usr/bin/env bash
# Remove the dsh-ops services.
# Default: stop/disable services, remove units, drop shell aliases.
#          Keeps the repo, DSH_HOME (~/.dsh data), and the node/pnpm toolchain.
# --purge: also removes the repo checkout, harness builds, and the dsh-ops
#          profile layer (the operator-surface plugin + cordis.patch.yml, only
#          when unmodified). Toolchain and ~/.dsh data stay.
# --dry-run: print what would happen, change nothing.
set -euo pipefail

OPS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_DIR="${DSH_HOME:-$HOME/.dsh}/profiles/web"
PATCH="$PROFILE_DIR/cordis.patch.yml"
PLUGIN="$PROFILE_DIR/dsh-ops-operator-surface.mjs"
TEMPLATE="$OPS/harness/cordis.patch.web.yml"
DRY_RUN=0
PURGE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --purge) PURGE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) echo "usage: uninstall.sh [--purge] [--dry-run]"; exit 0 ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac
done

run() {
  if [ "$DRY_RUN" = 1 ]; then echo "+ $*"; else "$@"; fi
}

run systemctl --user stop dsh-web.service dsh-go.service dsh-proxy.service 2>/dev/null || true
run systemctl --user disable dsh-web.service dsh-go.service dsh-proxy.service dsh-update.timer 2>/dev/null || true
for u in dsh-web.service dsh-go.service dsh-proxy.service dsh-update.service dsh-update.timer; do
  if [ -f ~/.config/systemd/user/$u ]; then
    run rm ~/.config/systemd/user/$u
  fi
done
run systemctl --user daemon-reload

if grep -q '^alias dsh-\(update\|url\|logs\)=' ~/.bashrc 2>/dev/null; then
  if [ "$DRY_RUN" = 1 ]; then
    echo "+ sed -i '/^alias dsh-(update|url|logs)=/d' ~/.bashrc"
  else
    sed -i '/^alias dsh-\(update\|url\|logs\)=/d' ~/.bashrc
  fi
fi

if [ "$PURGE" = 1 ]; then
  # The patch and the plugin it mounts go together: dropping one without the
  # other leaves a row pointing at a missing module.
  if [ -f "$PATCH" ] && cmp -s "$PATCH" "$TEMPLATE"; then
    run rm -f "$PATCH" "$PATCH.bak" "$PLUGIN"
  elif [ -f "$PATCH" ]; then
    echo "uninstall: keeping $PATCH (edited by hand; remove it and $PLUGIN manually)"
  elif [ -f "$PLUGIN" ]; then
    run rm -f "$PLUGIN"
  fi
  run rm -rf "$OPS"
fi

echo "uninstall: done (purge=$PURGE, dry-run=$DRY_RUN)"
