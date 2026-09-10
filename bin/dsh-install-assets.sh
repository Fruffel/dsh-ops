#!/usr/bin/env bash
# Render this checkout into the machine-local dsh-ops assets:
#   * systemd user units (WorkingDirectory/ExecStart point at THIS checkout)
#   * the web profile layer: the operator-surface plugin plus the
#     cordis.patch.yml that mounts it
#
# Ownership rule: a file carrying the `dsh-ops:managed` marker is ours and is
# refreshed in place (previous copy kept as *.bak). A file without the marker
# belongs to the operator and is never overwritten. Safe to re-run.
#
# The last output line is `assets: changed=<n>`, so a caller can tell whether
# the machine needs a service restart afterwards.
#
# usage: dsh-install-assets.sh [--dry-run]
set -euo pipefail

OPS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
DSH_HOME_DIR="${DSH_HOME:-$HOME/.dsh}"
PROFILE_DIR="$DSH_HOME_DIR/profiles/web"
PATCH_SRC="$OPS/harness/cordis.patch.web.yml"
PATCH_DST="$PROFILE_DIR/cordis.patch.yml"
PLUGIN_SRC="$OPS/plugins/dsh-ops-operator-surface.mjs"
PLUGIN_DST="$PROFILE_DIR/dsh-ops-operator-surface.mjs"
MARKER='dsh-ops:managed'
DRY_RUN=0
CHANGED=0

case "${1:-}" in
  --dry-run) DRY_RUN=1 ;;
  "") ;;
  *) echo "usage: dsh-install-assets.sh [--dry-run]"; exit 2 ;;
esac

# Unit templates carry @@OPS@@ where the checkout path belongs.
install_units() {
  local src name dst rendered
  mkdir -p "$UNIT_DIR"
  for src in "$OPS"/systemd/*.service "$OPS"/systemd/*.timer; do
    name="$(basename "$src")"
    dst="$UNIT_DIR/$name"
    rendered="$(mktemp)"
    sed "s|@@OPS@@|$OPS|g" "$src" > "$rendered"
    if [ -f "$dst" ] && cmp -s "$rendered" "$dst"; then
      rm -f "$rendered"
      continue
    fi
    if [ "$DRY_RUN" = 1 ]; then
      echo "+ install $name"
      rm -f "$rendered"
    else
      install -m 644 "$rendered" "$dst"
      rm -f "$rendered"
      echo "unit: installed $name"
    fi
    CHANGED=$((CHANGED + 1))
  done
}

# The profile layer: one plugin file (always ours) plus the patch that mounts it.
install_profile_layer() {
  mkdir -p "$PROFILE_DIR"

  if [ -f "$PLUGIN_DST" ] && cmp -s "$PLUGIN_SRC" "$PLUGIN_DST"; then
    echo "profile: operator-surface plugin already current"
  else
    if [ "$DRY_RUN" = 1 ]; then
      echo "+ install $(basename "$PLUGIN_DST")"
    else
      cp -f "$PLUGIN_SRC" "$PLUGIN_DST"
      echo "profile: installed $(basename "$PLUGIN_DST")"
    fi
    CHANGED=$((CHANGED + 1))
  fi

  # A file is ours when it carries the marker. The legacy header is accepted
  # once, so the pre-marker layer this repo shipped upgrades in place; both are
  # backed up to .bak before the replacement lands.
  if [ -f "$PATCH_DST" ] && ! grep -qE "$MARKER|Managed by dsh-ops" "$PATCH_DST"; then
    echo "profile: KEPT $PATCH_DST (no '$MARKER' marker, so it is operator-owned)"
    echo "profile: to adopt the dsh-ops layer, move that file aside and re-run this script"
    return 0
  fi
  if [ -f "$PATCH_DST" ] && cmp -s "$PATCH_SRC" "$PATCH_DST"; then
    echo "profile: cordis.patch.yml already current"
    return 0
  fi
  if [ -f "$PATCH_DST" ]; then
    if [ "$DRY_RUN" = 1 ]; then
      echo "+ save $(basename "$PATCH_DST").bak"
    else
      cp -f "$PATCH_DST" "$PATCH_DST.bak"
      echo "profile: previous layer saved as $(basename "$PATCH_DST").bak"
    fi
  fi
  if [ "$DRY_RUN" = 1 ]; then
    echo "+ install cordis.patch.yml"
  else
    cp -f "$PATCH_SRC" "$PATCH_DST"
    echo "profile: installed cordis.patch.yml"
  fi
  CHANGED=$((CHANGED + 1))
}

install_units
install_profile_layer
echo "assets: checkout $OPS -> $UNIT_DIR, $PROFILE_DIR (dry-run=$DRY_RUN)"
echo "assets: changed=$CHANGED"
