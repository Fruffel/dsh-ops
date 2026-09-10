#!/usr/bin/env bash
# Bootstrap a machine for dsh-ops: pnpm, the user units (+ daily timer), and the
# web profile layer (operator-surface package + cordis.patch.yml).
#
# It installs a service, nothing else: no aliases, no commands on PATH, no edits
# to your shell files. Run the scripts in bin/ directly, or via npm run.
# Safe to re-run. Touches nothing in DSH_HOME except that profile layer.
set -euo pipefail

OPS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$HOME/.local/node/bin:$PATH"

command -v node >/dev/null || { echo "install: node not found at ~/.local/node/bin"; exit 1; }
node -v

if ! command -v pnpm >/dev/null; then
  echo "install: installing standalone pnpm 11.7.0 (upstream pin)"
  export PNPM_HOME="$HOME/.local/share/pnpm"
  mkdir -p "$PNPM_HOME"
  curl -fsSL https://get.pnpm.io/install.sh | PNPM_VERSION=11.7.0 SHELL=/bin/bash bash -
fi
# Enforce the pinned major even if a pnpm already existed.
if [ "$(pnpm -v 2>/dev/null)" != "11.7.0" ]; then
  echo "install: switching pnpm to 11.7.0 (upstream pin)"
  curl -fsSL https://get.pnpm.io/install.sh | PNPM_VERSION=11.7.0 SHELL=/bin/bash bash -
fi
export PATH="$HOME/.local/share/pnpm/bin:$PATH"
pnpm -v

mkdir -p ~/.config/systemd/user
chmod +x "$OPS/bin/"*.sh

# Machine-local settings: created once, then owned by the operator (git-ignored).
if [ ! -f "$OPS/dsh-ops.conf" ]; then
  cp "$OPS/dsh-ops.conf.example" "$OPS/dsh-ops.conf"
  echo "install: wrote $OPS/dsh-ops.conf — set DSH_TRUSTED_HOSTS there if you reach"
  echo "install:          this host by NAME; by IP everything already works"
fi

# Units (rendered with this checkout's path and dsh-ops.conf) + profile layer.
"$OPS/bin/dsh-install-assets.sh"

systemctl --user daemon-reload
systemctl --user enable dsh-web.service dsh-go.service dsh-update.timer
systemctl --user start dsh-update.timer dsh-go.service

# Earlier versions wired the commands into the login shell; the service needs
# none of that, so a re-run of this script takes it back out.
retire_shell_wiring() {
  local cmd file="$HOME/.bashrc"
  for cmd in dsh-update dsh-url dsh-logs; do
    [ -L "$HOME/.local/bin/$cmd" ] && rm -f "$HOME/.local/bin/$cmd" && echo "install: removed ~/.local/bin/$cmd"
  done
  [ -f "$file" ] || return 0
  if grep -q -e '^alias dsh-\(update\|url\|logs\)=' -e '^# dsh-ops helpers$' "$file"; then
    sed -i '/^alias dsh-\(update\|url\|logs\)=/d; /^# dsh-ops helpers$/d; /^export PATH="\$HOME\/\.local\//d' "$file"
    echo "install: cleaned the dsh-ops lines out of ~/.bashrc"
  fi
}
retire_shell_wiring

echo "install: done. Next: $OPS/bin/dsh-sync.sh --dry-run"
echo "install: daily updates are already enabled (dsh-update.timer, 03:00)"
echo "install: run one now with ./bin/dsh-sync.sh, or npm run update"
echo "install: reach this host by IP out of the box; add any hostname you type to"
echo "install: DSH_TRUSTED_HOSTS in $OPS/dsh-ops.conf, then re-run this script"
