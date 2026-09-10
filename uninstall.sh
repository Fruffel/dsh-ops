#!/usr/bin/env bash
# Remove the dsh-ops services.
# Default: stop/disable services, remove units, drop shell aliases.
#          Keeps the repo, DSH_HOME (~/.dsh data), and the node/pnpm toolchain.
# --purge: also removes the repo checkout, harness builds, and our profile
#          patch layer (only if unmodified). toolchain + ~/.dsh data stay.
# --dry-run: print what would happen, change nothing.
set -euo pipefail
OPS="$HOME/Documents/dsh-ops"
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
    echo "+ sed -i '/^alias dsh-(update|url|logs)=/d; /^# dsh-ops helpers\$/d' ~/.bashrc"
  else
    sed -i '/^alias dsh-\(update\|url\|logs\)=/d; /^# dsh-ops helpers$/d' ~/.bashrc
  fi
fi

if [ "$PURGE" = 1 ]; then
  PATCH=~/.dsh/profiles/web/cordis.patch.yml
  if [ -f "$PATCH" ] && [ -f "$OPS/harness/cordis.patch.web.yml" ]; then
    if cmp -s "$PATCH" "$OPS/harness/cordis.patch.web.yml"; then
      run rm "$PATCH"
    else
      echo "uninstall: keeping modified $PATCH"
    fi
  fi
  run cd "$HOME"
  run rm -rf "$OPS"
fi

echo "uninstall: done (purge=$PURGE, dry-run=$DRY_RUN)"
