#!/usr/bin/env bash
# Render this checkout into the machine-local dsh-ops assets:
#   * systemd user units (WorkingDirectory/ExecStart point at THIS checkout)
#   * the web profile layer: every plugin package (this repo's own under layer/,
#     plus the checkouts under plugins/) and the generated cordis.patch.yml that
#     mounts them
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
LOCAL_PATCH="$OPS/harness/cordis.patch.local.yml"
# Two sources of plugin packages, and the difference matters:
#   layer/    dsh-ops' own packages, committed here because every deployment
#             needs them (the remote-settings surface).
#   plugins/  checkouts of the repositories named in plugins.conf and
#             plugins.local.conf, installed by bin/dsh-plugins.sh. Git-ignored:
#             the repositories stay the source of truth.
LAYER_DIR="$OPS/layer"
PLUGIN_DIR="$OPS/plugins"
LEGACY_PLUGIN="$PROFILE_DIR/dsh-ops-operator-surface.mjs"
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
DSH_UPDATE_CHANNEL=rc
DSH_AUTO_UPDATE=0
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

# Copy one file into the profile layer unless it is already identical. Files
# carry no marker of their own, so ownership is decided by the package
# directory: everything under a plugin package belongs to this repo.
install_plugin_file() {
  local src="$1" dst="$2"
  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
    return 1
  fi
  if [ "$DRY_RUN" = 1 ]; then
    echo "+ install $3"
  else
    mkdir -p "$(dirname "$dst")"
    cp -f "$src" "$dst"
    echo "profile: installed $3"
  fi
  CHANGED=$((CHANGED + 1))
  return 0
}

# Every plugin package — this repo's own under layer/, plus every checkout under
# plugins/ — is copied into the profile directory, where the generated patch
# mounts it. Installing a plugin is therefore one step: name its repository in
# plugins.conf (or drop a package in layer/) and re-run this script. No row to
# write, no script to edit, and no way to mount something that is not there.
#
# Each is a versioned package of its own because official DeepSeek requests
# inventory every active Loader module, and a relative file whose nearest named
# package.json has no version fails with REQUEST_EXTENSION.
install_plugin_packages() {
  local src name dst file changed relative
  for src in "$LAYER_DIR"/*/ "$PLUGIN_DIR"/*/; do
    src="${src%/}"
    [ -f "$src/package.json" ] || continue
    name="$(basename "$src")"
    dst="$PROFILE_DIR/$name"
    changed=0
    mkdir -p "$dst"
    # Every file of the package travels, nested paths included, so a plugin can
    # keep its modules in lib/ and its tests beside them.
    while IFS= read -r file; do
      relative="${file#"$src"/}"
      if install_plugin_file "$file" "$dst/$relative" "$name/$relative"; then
        changed=1
      fi
    done < <(find "$src" -type f -not -path '*/.git/*' -not -path '*/node_modules/*' | sort)
    if [ "$changed" = 0 ]; then
      echo "profile: plugin $name already current"
    fi
  done
}

# The profile layer: the plugin packages plus the patch that mounts them.
render_profile_patch() {
  local out="$1" file dir name main rows=0
  cat "$PATCH_SRC" > "$out"
  for file in "$LAYER_DIR"/*/package.json "$PLUGIN_DIR"/*/package.json; do
    [ -f "$file" ] || continue
    dir="$(dirname "$file")"
    name="$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$file" | head -n 1)"
    [ -n "$name" ] || name="$(basename "$dir")"
    main="$(sed -n 's/.*"main"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$file" | head -n 1)"
    [ -n "$main" ] || main="index.mjs"
    printf '\n# %s\n- insert:\n    - id: %s\n      name: ./%s/%s\n' \
      "$(basename "$dir")" "$name" "$(basename "$dir")" "$main" >> "$out"
    rows=$((rows + 1))
  done
  if [ -f "$LOCAL_PATCH" ]; then
    printf '\n# == %s (operator-owned)\n' "$(basename "$LOCAL_PATCH")" >> "$out"
    cat "$LOCAL_PATCH" >> "$out"
  fi
  echo "$rows"
}

install_profile_layer() {
  local rendered mount_rows
  mkdir -p "$PROFILE_DIR"

  install_plugin_packages
  rendered="$(mktemp)"
  mount_rows="$(render_profile_patch "$rendered")"
  # A file is ours when it carries the marker. The legacy header is accepted
  # once, so the pre-marker layer this repo shipped upgrades in place; both are
  # backed up to .bak before the replacement lands. An operator-owned patch is
  # left alone, including any leftover loose plugin file it may still mount.
  if [ -f "$PATCH_DST" ] && ! grep -qE "$MARKER|Managed by dsh-ops" "$PATCH_DST"; then
    echo "profile: KEPT $PATCH_DST (no '$MARKER' marker, so it is operator-owned)"
    echo "profile: to adopt the dsh-ops layer, move that file aside and re-run this script"
    rm -f "$rendered"
    return 0
  fi
  if [ -f "$PATCH_DST" ] && cmp -s "$rendered" "$PATCH_DST"; then
    echo "profile: cordis.patch.yml already current ($mount_rows plugin row(s))"
  else
    if [ -f "$PATCH_DST" ]; then
      if [ "$DRY_RUN" = 1 ]; then
        echo "+ save $(basename "$PATCH_DST").bak"
      else
        cp -f "$PATCH_DST" "$PATCH_DST.bak"
        echo "profile: previous layer saved as $(basename "$PATCH_DST").bak"
      fi
    fi
    if [ "$DRY_RUN" = 1 ]; then
      echo "+ install cordis.patch.yml ($mount_rows plugin row(s))"
    else
      cp -f "$rendered" "$PATCH_DST"
      echo "profile: installed cordis.patch.yml ($mount_rows plugin row(s))"
    fi
    CHANGED=$((CHANGED + 1))
  fi

  rm -f "$rendered"

  if [ -f "$LEGACY_PLUGIN" ]; then
    if [ "$DRY_RUN" = 1 ]; then
      echo "+ retire $(basename "$LEGACY_PLUGIN")"
    else
      rm -f "$LEGACY_PLUGIN"
      echo "profile: retired $(basename "$LEGACY_PLUGIN") (plugin is now a package)"
    fi
    CHANGED=$((CHANGED + 1))
  fi
}

# The daily timer is opt-in. DSH_AUTO_UPDATE=1 in dsh-ops.conf keeps the old
# behavior (a nightly sync at 03:00); the default, 0, leaves the machine to be
# updated from the GUI's Settings -> Updates page or by hand. The unit itself
# stays installed and startable either way: the GUI starts exactly that unit,
# because it runs the update in a cgroup that survives the dsh-web restart at
# the end of it.
apply_update_timer() {
  local unit="dsh-update.timer" wanted verb
  if [ "$DSH_AUTO_UPDATE" = 1 ]; then wanted="enabled"; verb="enable"; else wanted="disabled"; verb="disable"; fi
  if ! command -v systemctl >/dev/null 2>&1 || ! systemctl --user show-environment >/dev/null 2>&1; then
    echo "timer: no systemd user session here; left $unit alone (want $wanted)"
    return 0
  fi
  local state
  state="$(systemctl --user is-enabled "$unit" 2>/dev/null || true)"
  if [ "$state" = "$wanted" ]; then
    echo "timer: $unit already $wanted"
    return 0
  fi
  if [ "$DRY_RUN" = 1 ]; then
    echo "+ $verb $unit"
    return 0
  fi
  if systemctl --user "$verb" --now "$unit" 2>/dev/null; then
    echo "timer: $unit $wanted ($([ "$wanted" = enabled ] && echo 'daily 03:00' || echo 'updates are on demand'))"
  else
    echo "timer: could not $verb $unit (does the unit exist yet? re-run this script)"
  fi
}

# Make sure every plugin the manifest names is checked out. --install clones what
# is missing and never touches an existing checkout, so it is safe on every
# refresh; *updating* a checkout is a separate decision (bin/dsh-plugins.sh
# --update, or the button in Settings -> Updates).
install_plugins() {
  if [ ! -x "$OPS/bin/dsh-plugins.sh" ]; then
    echo "profile: no bin/dsh-plugins.sh; skipping plugin checkouts"
    return 0
  fi
  if [ "$DRY_RUN" = 1 ]; then
    echo "+ install missing plugin checkouts (bin/dsh-plugins.sh --install)"
    return 0
  fi
  # Nested: an --update run calls this script, and that call must not truncate
  # the outer run's own log or progress record.
  DSH_PLUGINS_NESTED=1 "$OPS/bin/dsh-plugins.sh" --install | sed 's/^/plugins: /'
}

# Retire first: the harness must be able to take the address a retired unit held.
retire_units
install_units
# Checkouts first: the packages copied below are whatever the manifest installs.
install_plugins
install_profile_layer
# Directory the updater writes its progress into (harness/state/update.json and
# update.log). Owned by the operator, not by this script: existing contents are
# never touched.
mkdir -p "$OPS/harness/state"
apply_update_timer
echo "assets: config $CONF (ports $DSH_PORT/$DSH_GO_PORT, trusted names: ${DSH_TRUSTED_HOSTS:-none})"
echo "assets: updates channel=${DSH_UPDATE_CHANNEL:-rc} daily-timer=$([ "$DSH_AUTO_UPDATE" = 1 ] && echo on || echo off)"
echo "assets: checkout $OPS -> $UNIT_DIR, $PROFILE_DIR (dry-run=$DRY_RUN)"
echo "assets: changed=$CHANGED"
