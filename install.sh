#!/usr/bin/env bash
# Bootstrap kamer-ts for dsh-ops: pnpm, units, timer, aliases.
# Safe to re-run. Does not touch DSH_HOME (~/.dsh) or the running DSH.
set -euo pipefail
OPS="$HOME/Documents/dsh-ops"
export PATH="$HOME/.local/node/bin:$PATH"

command -v node >/dev/null || { echo "install: node not found at ~/.local/node/bin"; exit 1; }
node -v

if ! command -v pnpm >/dev/null; then
  echo "install: installing standalone pnpm"
  export PNPM_HOME="$HOME/.local/share/pnpm"
  mkdir -p "$PNPM_HOME"
  curl -fsSL https://get.pnpm.io/install.sh | SHELL=/bin/bash bash -
fi
export PATH="$HOME/.local/share/pnpm:$PATH"
pnpm -v

mkdir -p ~/.config/systemd/user
for u in dsh-web.service dsh-proxy.service dsh-update.service dsh-update.timer; do
  cp "$OPS/systemd/$u" ~/.config/systemd/user/$u
done
systemctl --user daemon-reload

grep -q 'dsh-ops helpers' ~/.bashrc || cat >> ~/.bashrc <<'BLOCK'

# dsh-ops helpers
export PATH="$HOME/.local/share/pnpm:$HOME/.local/node/bin:$PATH"
alias dsh-update="$HOME/Documents/dsh-ops/bin/dsh-sync.sh"
alias dsh-url="$HOME/Documents/dsh-ops/bin/dsh-url.sh"
alias dsh-logs='journalctl --user -u dsh-web -u dsh-proxy -f'
BLOCK

# Retire the previous npm-era aliases if present.
sed -i 's|^alias dsh-update=.*|alias dsh-update="$HOME/Documents/dsh-ops/bin/dsh-sync.sh"|; s|^alias dsh-url=.*|alias dsh-url="$HOME/Documents/dsh-ops/bin/dsh-url.sh"|' ~/.bashrc

echo "install: done. Next: bin/dsh-sync.sh --dry-run"
