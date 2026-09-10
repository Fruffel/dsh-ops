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

# Commands as real executables on PATH, not aliases: that way scripts, other
# shells, and "ssh -t <host> dsh-update" all resolve them. Re-pointed at this
# checkout on every run.
mkdir -p "$HOME/.local/bin"
ln -sfn "$OPS/bin/dsh-sync.sh" "$HOME/.local/bin/dsh-update"
ln -sfn "$OPS/bin/dsh-url.sh" "$HOME/.local/bin/dsh-url"
ln -sfn "$OPS/bin/dsh-logs.sh" "$HOME/.local/bin/dsh-logs"

# Keep the login-shell PATH current, and drop what earlier installs left behind
# (aliases, and this block itself, which is rewritten rather than duplicated).
sed -i '/^alias dsh-\(update\|url\|logs\)=/d' ~/.bashrc
sed -i '/^# dsh-ops helpers$/d; /^export PATH="\$HOME\/\.local\//d' ~/.bashrc
cat >> ~/.bashrc <<'BLOCK'

# dsh-ops helpers
export PATH="$HOME/.local/bin:$HOME/.local/share/pnpm/bin:$HOME/.local/node/bin:$PATH"
BLOCK

echo "install: done. Next: $OPS/bin/dsh-sync.sh --dry-run"
echo "install: reach this host by IP out of the box; add any hostname you type to"
echo "install: DSH_TRUSTED_HOSTS in $OPS/dsh-ops.conf, then re-run this script"
