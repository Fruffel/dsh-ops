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

# The checkout is found through the script itself, not through the path it was
# called by: dsh-update and friends are symlinks in ~/.local/bin.
SELF="${BASH_SOURCE[0]}"
if command -v readlink >/dev/null 2>&1; then
  SELF="$(readlink -f "$SELF" 2>/dev/null || printf '%s' "$SELF")"
fi
OPS="$(cd "$(dirname "$SELF")/.." && pwd)"
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

# Machine-local settings live in the checkout, git-ignored, so the daily updater
# re-renders the same units instead of dropping them. Defaults suit a plain
# 0.0.0.0 deployment reached by IP.
CONF="$OPS/dsh-ops.conf"
DSH_PORT=3080
DSH_GO_PORT=3081
DSH_TRUSTED_HOSTS=""
if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090 -- operator-owned file beside this checkout
  . "$CONF"
fi
case "$DSH_PORT$DSH_GO_PORT" in
  *[!0-9]*) echo "dsh-install-assets: DSH_PORT and DSH_GO_PORT must be numbers ($CONF)" >&2; exit 2 ;;
esac

# --trusted-host accepts one authority per flag, so one flag per configured name.
# The leading space is deliberate: the unit template appends this immediately
# after the port, and an empty list must leave no argument behind.
TRUSTED_HOST_ARGS=""
for authority in $DSH_TRUSTED_HOSTS; do
  TRUSTED_HOST_ARGS="$TRUSTED_HOST_ARGS --trusted-host $authority"
done

# sed replacement text: backslash, the delimiter, and & all need escaping.
escape_replacement() {
  printf '%s' "$1" | sed -e 's/[&|\\]/\\&/g'
}

render_unit() {
  sed -e "s|@@OPS@@|$(escape_replacement "$OPS")|g" \
      -e "s|@@DSH_PORT@@|$(escape_replacement "$DSH_PORT")|g" \
      -e "s|@@DSH_GO_PORT@@|$(escape_replacement "$DSH_GO_PORT")|g" \
      -e "s|@@TRUSTED_HOSTS@@|$(escape_replacement "$TRUSTED_HOST_ARGS")|g" "$1" > "$2"
}

case "${1:-}" in
  --dry-run) DRY_RUN=1 ;;
  "") ;;
  *) echo "usage: dsh-install-assets.sh [--dry-run]"; exit 2 ;;
esac

# Units this repo shipped once and no longer does. Retiring them here keeps a
# pulled checkout authoritative over whatever a machine still has installed --
# dsh-proxy held the tailnet address, which the harness now binds itself.
RETIRED_UNITS='dsh-proxy.service'

retire_units() {
  local unit
  for unit in $RETIRED_UNITS; do
    [ -f "$UNIT_DIR/$unit" ] || continue
    if [ "$DRY_RUN" = 1 ]; then
      echo "+ retire $unit"
    else
      systemctl --user stop "$unit" 2>/dev/null || true
      systemctl --user disable "$unit" 2>/dev/null || true
      rm -f "$UNIT_DIR/$unit"
      echo "unit: retired $unit"
    fi
    CHANGED=$((CHANGED + 1))
  done
}

# Unit templates carry @@OPS@@ where the checkout path belongs.
install_units() {
  local src name dst rendered
  mkdir -p "$UNIT_DIR"
  for src in "$OPS"/systemd/*.service "$OPS"/systemd/*.timer; do
    name="$(basename "$src")"
    dst="$UNIT_DIR/$name"
    rendered="$(mktemp)"
    render_unit "$src" "$rendered"
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

# Retire first: the harness must be able to take the address a retired unit held.
retire_units
install_units
install_profile_layer
echo "assets: config $CONF (ports $DSH_PORT/$DSH_GO_PORT, trusted names: ${DSH_TRUSTED_HOSTS:-none})"
echo "assets: checkout $OPS -> $UNIT_DIR, $PROFILE_DIR (dry-run=$DRY_RUN)"
echo "assets: changed=$CHANGED"
