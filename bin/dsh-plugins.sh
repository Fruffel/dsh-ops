#!/usr/bin/env bash
# Install and update this deployment's plugins.
#
# dsh-ops carries a manifest, not plugin code: plugins.conf lists plugin
# repositories (plugins.local.conf, git-ignored, adds machine-local checkouts),
# and this script clones each one into plugins/ — also git-ignored — which is
# what the profile layer mounts. The harness gets exactly the same treatment
# from bin/dsh-sync.sh: the repository holds the recipe, the checkout holds the
# code.
#
# Modes:
#   --install   clone what is missing. Never touches an existing checkout, so
#               it is safe to run on every asset refresh.
#   --update    the same, then fast-forward what is already there. A checkout
#               with local changes is reported and left alone.
#   --check     report what is installed and what upstream has. Clones nothing,
#               pulls nothing: it only asks the remote with `git ls-remote`.
#   --json      machine-readable output for --check.
#
# Every --update run leaves harness/state/plugins.json and plugins.log, the
# same convention bin/dsh-sync.sh uses, so the GUI can follow a run it started.
set -euo pipefail

# The checkout is found through the script itself, not through the path it was
# called by: these scripts are also reachable through ~/.local/bin symlinks.
SELF="${BASH_SOURCE[0]}"
if command -v readlink >/dev/null 2>&1; then
  SELF="$(readlink -f "$SELF" 2>/dev/null || printf '%s' "$SELF")"
fi
OPS="$(cd "$(dirname "$SELF")/.." && pwd)"
PLUGIN_DIR="$OPS/plugins"
CONF="$OPS/plugins.conf"
LOCAL_CONF="$OPS/plugins.local.conf"
STATE_DIR="$OPS/harness/state"
STATUS="$STATE_DIR/plugins.json"
LOG_FILE="$STATE_DIR/plugins.log"
export PATH="$HOME/.local/share/pnpm/bin:$HOME/.local/node/bin:$PATH"

MODE="install"
JSON=0
# 1 when this script was invoked by bin/dsh-install-assets.sh (which an --update
# run calls at the end): the nested call must not truncate the outer run's log or
# overwrite its progress record.
NESTED="${DSH_PLUGINS_NESTED:-0}"

usage() {
  echo "usage: dsh-plugins.sh [--install|--update|--check|--list] [--json]"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --install) MODE="install"; shift ;;
    --update) MODE="update"; shift ;;
    --check) MODE="check"; shift ;;
    --list) MODE="list"; shift ;;
    --json) JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1"; usage; exit 2 ;;
  esac
done
if [ "$JSON" = 1 ] && [ "$MODE" != "check" ]; then
  echo "dsh-plugins: --json is only meaningful with --check"
  exit 2
fi

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Quote one string as JSON (tags, URLs, paths and git's own diagnostics).
json_string() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/}"
  s="${s//$'\t'/\\t}"
  printf '"%s"' "$s"
}

# Print the line and append it to the run's log, so a GUI watching the log and
# a terminal running this by hand see the same narrative.
LOG_READY=0
say() {
  printf '%s\n' "$*"
  if [ "$LOG_READY" = 1 ]; then
    printf '%s %s\n' "$(now_iso)" "$*" >> "$LOG_FILE"
  fi
}

STARTED_AT=""
FINISHED_AT=""
RUN_STATE="ok"
RUN_PHASE="done"
RUN_MESSAGE=""
STATE_ENTRIES=""

# Progress record the GUI reads; written atomically so a reader never sees half
# a file. `entries` is a pre-rendered JSON array.
write_status() {
  local state="$1" phase="$2" message="$3"
  [ "$NESTED" = 1 ] && return 0
  [ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR"
  local tmp="$STATUS.$$"
  {
    printf '{\n'
    printf '  "state": %s,\n' "$(json_string "$state")"
    printf '  "phase": %s,\n' "$(json_string "$phase")"
    printf '  "message": %s,\n' "$(json_string "$message")"
    printf '  "pid": %d,\n' "$$"
    printf '  "startedAt": %s,\n' "$([ -n "$STARTED_AT" ] && json_string "$STARTED_AT" || printf 'null')"
    printf '  "finishedAt": %s,\n' "$([ -n "$FINISHED_AT" ] && json_string "$FINISHED_AT" || printf 'null')"
    printf '  "updatedAt": %s,\n' "$(json_string "$(now_iso)")"
    if [ -n "$STATE_ENTRIES" ]; then
      printf '  "entries": [%s]\n' "$STATE_ENTRIES"
    else
      printf '  "entries": []\n'
    fi
    printf '}\n'
  } > "$tmp"
  mv -f "$tmp" "$STATUS"
}

# The directory a manifest entry installs into: the repository name, without a
# trailing slash or the .git suffix.
entry_name() {
  local url="$1" name
  name="${url%/}"
  name="${name##*/}"
  name="${name%.git}"
  printf '%s' "$name"
}

# Every manifest entry as "<url>|<ref>|<name>|<source>", in file order.
# The separator is "|" rather than a tab on purpose: a tab is IFS whitespace, so
# `read` collapses consecutive ones and an absent ref would shift every field.
# Later files win a name collision (plugins.local.conf overrides plugins.conf),
# so a machine can point an entry at its own checkout.
manifest_entries() {
  local file line url ref name seen=""
  for file in "$CONF" "$LOCAL_CONF"; do
    [ -f "$file" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%%#*}"
      line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      [ -n "$line" ] || continue
      # shellcheck disable=SC2086 -- two whitespace-separated fields by design
      set -- $line
      url="$1"
      ref="${2:-}"
      name="$(entry_name "$url")"
      [ -n "$name" ] || continue
      # shellcheck disable=SC2086 -- newline-separated list
      case "$(printf '%s\n' $seen)" in
        *"$name"*) continue ;;
      esac
      seen="$seen $name"
      printf '%s|%s|%s|%s\n' "$url" "$ref" "$name" "$(basename "$file")"
    done < "$file"
  done
}

# Whether a checkout has an origin to compare with and pull from.
has_origin() {
  git -C "$1" remote get-url origin >/dev/null 2>&1
}

# The commit a checkout is on, short, or "-" when there is none yet.
local_rev() {
  git -C "$1" rev-parse --short HEAD 2>/dev/null || printf '-'
}

# The commit the remote names for this entry, short, without touching the
# worktree: `git ls-remote` is a query, not a fetch.
remote_rev() {
  local dir="$1" ref="$2" out
  out="$(git -C "$dir" ls-remote origin "${ref:-HEAD}" 2>/dev/null | sed -n 1p)" || true
  printf '%s' "${out%%[[:space:]]*}" | cut -c1-7
}

# One entry, as a JSON object, using the values already resolved by the caller.
entry_json() {
  local name="$1" url="$2" ref="$3" source="$4" dir="$5" installed="$6" current="$7" latest="$8" available="$9" note="${10}"
  printf '{'
  printf '"name": %s, ' "$(json_string "$name")"
  printf '"url": %s, ' "$(json_string "$url")"
  printf '"ref": %s, ' "$([ -n "$ref" ] && json_string "$ref" || printf 'null')"
  printf '"source": %s, ' "$(json_string "$source")"
  printf '"directory": %s, ' "$(json_string "$dir")"
  printf '"installed": %s, ' "$installed"
  printf '"current": %s, ' "$([ -n "$current" ] && json_string "$current" || printf 'null')"
  printf '"latest": %s, ' "$([ -n "$latest" ] && json_string "$latest" || printf 'null')"
  printf '"updateAvailable": %s, ' "$available"
  printf '"note": %s' "$([ -n "$note" ] && json_string "$note" || printf 'null')"
  printf '}'
}

# ---- --list ---------------------------------------------------------------
if [ "$MODE" = list ]; then
  if [ ! -f "$CONF" ] && [ ! -f "$LOCAL_CONF" ]; then
    echo "dsh-plugins: no manifest ($CONF)"
    exit 0
  fi
  while IFS='|' read -r url ref name source; do
    [ -n "$name" ] || continue
    printf '%-28s %-12s %s%s\n' "$name" "$source" "$url" "$([ -n "$ref" ] && printf ' @%s' "$ref")"
  done < <(manifest_entries)
  exit 0
fi

# ---- --check --------------------------------------------------------------
if [ "$MODE" = check ]; then
  ENTRIES_JSON=""
  ANY_AVAILABLE=0
  UNMANAGED=0
  while IFS='|' read -r url ref name source; do
    [ -n "$name" ] || continue
    dir="$PLUGIN_DIR/$name"
    installed=false
    current=""
    latest=""
    available=false
    note=""
    if [ -d "$dir/.git" ]; then
      installed=true
      current="$(local_rev "$dir")"
      if has_origin "$dir"; then
        latest="$(remote_rev "$dir" "$ref")"
        if [ -z "$latest" ]; then
          note="remote did not answer"
        elif [ "$latest" != "$current" ]; then
          available=true
          ANY_AVAILABLE=1
        fi
      else
        note="no origin remote; this checkout is not managed here"
        UNMANAGED=$((UNMANAGED + 1))
      fi
    else
      available=true
      ANY_AVAILABLE=1
      note="not installed yet"
    fi
    [ -z "$ENTRIES_JSON" ] || ENTRIES_JSON="$ENTRIES_JSON, "
    ENTRIES_JSON="$ENTRIES_JSON$(entry_json "$name" "$url" "$ref" "$source" "$dir" "$installed" "$current" "$latest" "$available" "$note")"
  done < <(manifest_entries)

  if [ "$JSON" = 1 ]; then
    printf '{\n'
    printf '  "ok": true,\n'
    printf '  "pluginsDir": %s,\n' "$(json_string "$PLUGIN_DIR")"
    printf '  "updateAvailable": %s,\n' "$([ "$ANY_AVAILABLE" = 1 ] && printf 'true' || printf 'false')"
    printf '  "unmanaged": %d,\n' "$UNMANAGED"
    printf '  "entries": [%s],\n' "$ENTRIES_JSON"
    printf '  "checkedAt": %s\n' "$(json_string "$(now_iso)")"
    printf '}\n'
  else
    printf 'dsh-plugins: %s, manifest %s%s\n' "$PLUGIN_DIR" "$CONF" "$([ -f "$LOCAL_CONF" ] && printf ' + %s' "$LOCAL_CONF")"
    if [ -z "$ENTRIES_JSON" ]; then
      printf 'dsh-plugins: no plugins declared\n'
    else
      while IFS='|' read -r url ref name source; do
        [ -n "$name" ] || continue
        dir="$PLUGIN_DIR/$name"
        if [ ! -d "$dir/.git" ]; then
          printf '  %-28s not installed\n' "$name"
          continue
        fi
        if ! has_origin "$dir"; then
          printf '  %-28s %s (no origin remote)\n' "$name" "$(local_rev "$dir")"
          continue
        fi
        latest="$(remote_rev "$dir" "$ref")"
        current="$(local_rev "$dir")"
        if [ "$latest" = "$current" ]; then
          printf '  %-28s %s (current)\n' "$name" "$current"
        elif [ -z "$latest" ]; then
          printf '  %-28s %s (remote did not answer)\n' "$name" "$current"
        else
          printf '  %-28s %s -> %s (update available)\n' "$name" "$current" "$latest"
        fi
      done < <(manifest_entries)
    fi
  fi
  exit 0
fi

# ---- --install / --update -------------------------------------------------
mkdir -p "$STATE_DIR" "$PLUGIN_DIR"
if [ "$NESTED" = 0 ]; then
  : > "$LOG_FILE"
  LOG_READY=1
fi
STARTED_AT="$(now_iso)"
if [ "$MODE" = update ]; then
  write_status running start "updating plugins"
else
  write_status running start "installing plugins"
fi

CHANGED=0
FAILED=0
COUNT=0

# Record one entry's outcome in the state file's entries array.
record() {
  local name="$1" url="$2" action="$3" ok="$4" detail="$5"
  [ -z "$STATE_ENTRIES" ] || STATE_ENTRIES="$STATE_ENTRIES, "
  STATE_ENTRIES="$STATE_ENTRIES$(printf '{"name": %s, "url": %s, "action": %s, "ok": %s, "detail": %s}' \
    "$(json_string "$name")" "$(json_string "$url")" "$(json_string "$action")" "$ok" "$([ -n "$detail" ] && json_string "$detail" || printf 'null')")"
}

# Clone one entry or bring it up to date, depending on the mode.
sync_entry() {
  local url="$1" ref="$2" name="$3" dir="$PLUGIN_DIR/$3"
  COUNT=$((COUNT + 1))

  if [ ! -d "$dir/.git" ]; then
    if [ -e "$dir" ]; then
      say "dsh-plugins: $name: $dir exists but is not a git checkout; leaving it alone"
      record "$name" "$url" clone false "$dir is not a git checkout"
      FAILED=$((FAILED + 1))
      return 0
    fi
    say "dsh-plugins: $name: cloning $url${ref:+ @$ref}"
    write_status running clone "cloning $name"
    if [ -n "$ref" ]; then
      git clone --quiet --branch "$ref" "$url" "$dir" || {
        say "dsh-plugins: $name: clone failed"
        record "$name" "$url" clone false "clone failed"
        FAILED=$((FAILED + 1))
        rm -rf "$dir"
        return 0
      }
    else
      git clone --quiet "$url" "$dir" || {
        say "dsh-plugins: $name: clone failed"
        record "$name" "$url" clone false "clone failed"
        FAILED=$((FAILED + 1))
        rm -rf "$dir"
        return 0
      }
    fi
    CHANGED=$((CHANGED + 1))
    record "$name" "$url" clone true "$(local_rev "$dir")"
    return 0
  fi

  if [ "$MODE" != update ]; then
    record "$name" "$url" keep true "$(local_rev "$dir")"
    return 0
  fi

  if ! has_origin "$dir"; then
    say "dsh-plugins: $name: no origin remote, not managed here"
    record "$name" "$url" skip true "no origin remote"
    return 0
  fi
  if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
    say "dsh-plugins: $name: local changes present, leaving it alone"
    record "$name" "$url" skip true "local changes present"
    return 0
  fi

  local before after
  before="$(local_rev "$dir")"
  say "dsh-plugins: $name: fetching"
  write_status running fetch "fetching $name"
  if ! git -C "$dir" fetch --quiet origin; then
    say "dsh-plugins: $name: fetch failed"
    record "$name" "$url" fetch false "fetch failed"
    FAILED=$((FAILED + 1))
    return 0
  fi
  if [ -n "$ref" ]; then
    git -C "$dir" checkout --quiet "$ref" 2>/dev/null || true
    git -C "$dir" merge --quiet --ff-only FETCH_HEAD 2>/dev/null || {
      say "dsh-plugins: $name: cannot fast-forward to $ref"
      record "$name" "$url" pull false "cannot fast-forward to $ref"
      FAILED=$((FAILED + 1))
      return 0
    }
  elif ! git -C "$dir" merge --quiet --ff-only '@{upstream}' 2>/dev/null; then
    say "dsh-plugins: $name: no upstream branch to fast-forward; left at $before"
    record "$name" "$url" skip true "no upstream branch"
    return 0
  fi
  after="$(local_rev "$dir")"
  if [ "$before" = "$after" ]; then
    say "dsh-plugins: $name: already current ($after)"
    record "$name" "$url" keep true "$after"
  else
    say "dsh-plugins: $name: updated $before -> $after"
    CHANGED=$((CHANGED + 1))
    record "$name" "$url" update true "$before -> $after"
  fi
}

while IFS='|' read -r url ref name source; do
  [ -n "$name" ] || continue
  sync_entry "$url" "$ref" "$name"
done < <(manifest_entries)

if [ "$COUNT" = 0 ]; then
  RUN_MESSAGE="no plugins declared"
  say "dsh-plugins: no plugins declared in $CONF"
elif [ "$FAILED" != 0 ]; then
  RUN_STATE="failed"
  RUN_PHASE="failed"
  RUN_MESSAGE="$FAILED of $COUNT plugin(s) failed"
  say "dsh-plugins: $RUN_MESSAGE"
elif [ "$CHANGED" = 0 ]; then
  RUN_MESSAGE="$COUNT plugin(s) already current"
  say "dsh-plugins: $RUN_MESSAGE"
else
  RUN_MESSAGE="$CHANGED of $COUNT plugin(s) changed"
  say "dsh-plugins: $RUN_MESSAGE"
fi

[ "$FAILED" = 0 ] || {
  write_status "$RUN_STATE" "$RUN_PHASE" "$RUN_MESSAGE"
  exit 1
}

# An updated checkout is not a running plugin: the profile layer has to be
# refreshed from it and the harness restarted to mount the new code. Only when
# something actually changed — a no-op run must not bounce the services.
if [ "$MODE" = update ] && [ "$CHANGED" != 0 ]; then
  say "dsh-plugins: refreshing the profile layer"
  write_status running deploy "refreshing units and the profile layer"
  ASSETS_OUT="$("$OPS/bin/dsh-install-assets.sh")"
  printf '%s\n' "$ASSETS_OUT" | while IFS= read -r line; do say "$line"; done
  case "$ASSETS_OUT" in
    *"assets: changed=0"*) ;;
    *) CHANGED=$((CHANGED + 1)) ;;
  esac

  say "dsh-plugins: restarting the services"
  write_status running restart "restarting the services"
  systemctl --user daemon-reload
  if ! systemctl --user restart dsh-web.service; then
    FINISHED_AT="$(now_iso)"
    RUN_STATE="failed"
    RUN_PHASE="restart"
    RUN_MESSAGE="plugins updated, but dsh-web did not restart"
    say "dsh-plugins: $RUN_MESSAGE"
    write_status "$RUN_STATE" "$RUN_PHASE" "$RUN_MESSAGE"
    exit 1
  fi
  systemctl --user restart dsh-go.service \
    || say "dsh-plugins: WARNING: dsh-go restart failed (token-free entry may 503 until it is back)"
fi

FINISHED_AT="$(now_iso)"
write_status "$RUN_STATE" "$RUN_PHASE" "$RUN_MESSAGE"
