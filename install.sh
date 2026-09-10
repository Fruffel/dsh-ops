#!/usr/bin/env bash
# Bootstrap a machine for dsh-ops: pnpm, user units, timer, aliases, and the
# web profile layer (operator-surface plugin + cordis.patch.yml).
# Safe to re-run. Does not touch DSH_HOME data beyond that layer, and never
# touches the running DSH.
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

# Units (rendered with this checkout's path) + the web profile layer.
"$OPS/bin/dsh-install-assets.sh"

systemctl --user daemon-reload
systemctl --user enable dsh-web.service dsh-go.service dsh-update.timer
systemctl --user start dsh-update.timer dsh-go.service

grep -q 'dsh-ops helpers' ~/.bashrc || cat >> ~/.bashrc <<'BLOCK'

# dsh-ops helpers
export PATH="$HOME/.local/share/pnpm/bin:$HOME/.local/node/bin:$PATH"
BLOCK
# Rewrite the three aliases to this checkout on every run.
sed -i '/^alias dsh-\(update\|url\|logs\)=/d' ~/.bashrc
cat >> ~/.bashrc <<BLOCK
alias dsh-update="$OPS/bin/dsh-sync.sh"
alias dsh-url="$OPS/bin/dsh-url.sh"
alias dsh-logs='journalctl --user -u dsh-web -u dsh-go -f'
BLOCK

echo "install: done. Next: $OPS/bin/dsh-sync.sh --dry-run"
