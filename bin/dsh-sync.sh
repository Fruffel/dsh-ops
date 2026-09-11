#!/usr/bin/env bash
# Smart DSH updater: newest tag on a channel -> build -> smoke test -> swap.
# Never leaves the service on a broken build: failures keep `current` as-is.
#
# Two modes:
#   * update (default) — resolve, build, smoke test, swap, restart.
#   * --check          — resolve and report only; builds nothing, restarts
#                        nothing. This is what the GUI's Updates page calls.
#
# Every update run also leaves a machine-readable progress record in
# harness/state/update.json (and its output in update.log), which is what the
# GUI reads back while a run is in flight.
set -euo pipefail

# The checkout is found through the script itself, not through the path it was
# called by: dsh-update and friends are symlinks in ~/.local/bin.
SELF="${BASH_SOURCE[0]}"
if command -v readlink >/dev/null 2>&1; then
  SELF="$(readlink -f "$SELF" 2>/dev/null || printf '%s' "$SELF")"
fi
OPS="$(cd "$(dirname "$SELF")/.." && pwd)"
UPSTREAM="$OPS/harness/upstream"
BUILDS="$OPS/harness/builds"
CURRENT="$OPS/harness/current"
REF_FILE="$OPS/harness/current-ref"
STATE_DIR="$OPS/harness/state"
STATUS="$STATE_DIR/update.json"
LOG_FILE="$STATE_DIR/update.log"
export PATH="$HOME/.local/share/pnpm/bin:$HOME/.local/node/bin:$PATH"

# Machine-local settings live in the checkout (dsh-ops.conf, git-ignored). The
# channel is read from there so the timer, the GUI's Update button, and a
# terminal cannot disagree about which channel this machine follows; --channel
# still overrides for one run.
CONF="$OPS/dsh-ops.conf"
DSH_UPDATE_CHANNEL=""
if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090 -- operator-owned file beside this checkout
  . "$CONF"
fi

CHANNEL="${DSH_UPDATE_CHANNEL:-rc}"
DRY_RUN=0
CHECK=0
JSON=0
PIN_REF=""

usage() {
  echo "usage: dsh-sync.sh [--channel stable|rc|latest] [--ref <tag>] [--dry-run] [--check [--json]]"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --channel) CHANNEL="$2"; shift 2 ;;
    --ref) PIN_REF="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --check) CHECK=1; shift ;;
    --json) JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1"; usage; exit 2 ;;
  esac
done

case "$CHANNEL" in
  stable|rc|latest) ;;
  *) echo "dsh-sync: unknown channel: $CHANNEL"; exit 2 ;;
esac
if [ "$JSON" = 1 ] && [ "$CHECK" = 0 ]; then
  echo "dsh-sync: --json is only meaningful with --check"
  exit 2
fi

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Quote one string as JSON. The values written here are tags, channel names,
# timestamps and git's own diagnostics, so this only has to cover the control
# characters those can actually contain.
json_string() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/}"
  s="${s//$'\t'/\\t}"
  printf '"%s"' "$s"
}

[ -d "$UPSTREAM/.git" ] || {
  if [ "$CHECK" = 1 ] && [ "$JSON" = 1 ]; then
    printf '{\n  "ok": false,\n  "error": %s\n}\n' "$(json_string "no clone at $UPSTREAM (run install.sh)")"
    exit 1
  fi
  echo "dsh-sync: no clone at $UPSTREAM (run install.sh)"
  exit 1
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

# Progress record the GUI reads. Written atomically: a reader either sees the
# previous complete record or the next one, never a half-written file.
STARTED_AT=""
FINISHED_AT=""
STATE_DEPLOYED=""
write_status() {
  local state="$1" phase="$2" message="$3"
  [ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR"
  local tmp="$STATUS.$$"
  {
    printf '{\n'
    printf '  "state": %s,\n' "$(json_string "$state")"
    printf '  "phase": %s,\n' "$(json_string "$phase")"
    printf '  "message": %s,\n' "$(json_string "$message")"
    printf '  "channel": %s,\n' "$(json_string "$CHANNEL")"
    printf '  "target": %s,\n' "$(json_string "$TARGET")"
    printf '  "previous": %s,\n' "$(json_string "$STATE_DEPLOYED")"
    printf '  "pid": %d,\n' "$$"
    printf '  "startedAt": %s,\n' "$([ -n "$STARTED_AT" ] && json_string "$STARTED_AT" || printf 'null')"
    printf '  "finishedAt": %s,\n' "$([ -n "$FINISHED_AT" ] && json_string "$FINISHED_AT" || printf 'null')"
    printf '  "updatedAt": %s\n' "$(json_string "$(now_iso)")"
    printf '}\n'
  } > "$tmp"
  mv -f "$tmp" "$STATUS"
}

# Strip tag affixes to a bare semver-ish version: v1.2.3, dsh-v1.2.3-rc.1,
# @deepseek-ai/dsh@1.2.3-rc.1 -> 1.2.3-rc.1
bare_version() {
  local t="$1"
  t="${t##*@}"
  t="${t#dsh-}"
  t="${t#v}"
  printf '%s' "$t"
}

# Whether bare version $1 sorts strictly after $2. `sed -n 1p` rather than
# `head -n1` so the sort is never killed by a closed pipe under `pipefail`.
version_gt() {
  [ "$1" != "$2" ] || return 1
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -Vr | sed -n 1p)" = "$1" ]
}

# Every tag on the channel as "<version> <tag>", newest first.
channel_tags() {
  local tag v
  git -C "$UPSTREAM" tag --list | while read -r tag; do
    [ -n "$tag" ] || continue
    v="$(bare_version "$tag")"
    case "$CHANNEL" in
      stable) [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue ;;
      rc)     [[ "$v" =~ alpha ]] && continue ;;
      latest) ;;
    esac
    printf '%s %s\n' "$v" "$tag"
  done | sort -t' ' -k1,1Vr
}

# Refresh the clone. A check still answers when the network is down (from the
# tags already fetched) but says so; an update run must not proceed on a stale
# view of the tags, so it stops.
FETCH_ERROR=""
if ! FETCH_OUT="$(git -C "$UPSTREAM" fetch --quiet origin 2>&1)"; then
  FETCH_ERROR="git fetch origin: $(printf '%s' "$FETCH_OUT" | tail -n 1)"
fi
if [ -z "$FETCH_ERROR" ] && ! FETCH_OUT="$(git -C "$UPSTREAM" fetch --quiet --tags origin 2>&1)"; then
  FETCH_ERROR="git fetch --tags origin: $(printf '%s' "$FETCH_OUT" | tail -n 1)"
fi
if [ -n "$FETCH_ERROR" ] && [ "$CHECK" = 0 ]; then
  echo "dsh-sync: $FETCH_ERROR"
  exit 1
fi

TAGS="$(channel_tags)"
TARGET=""
if [ -n "$PIN_REF" ]; then
  git -C "$UPSTREAM" rev-parse --verify --quiet "refs/tags/$PIN_REF" >/dev/null \
    || { echo "dsh-sync: no such tag: $PIN_REF"; exit 1; }
  TARGET="$PIN_REF"
else
  TARGET_LINE="${TAGS%%$'\n'*}"
  TARGET="${TARGET_LINE#* }"
fi

DEPLOYED=""
[ -f "$REF_FILE" ] && DEPLOYED="$(cat "$REF_FILE")"

# What is already installed, for the report's "installed at" line.
INSTALLED_AT=""
if [ -f "$REF_FILE" ]; then
  INSTALLED_AT="$(date -u -d "@$(stat -c %Y "$REF_FILE")" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '')"
fi

# Everything on this channel that sorts after what is deployed, newest first.
NEWER=""
if [ -n "$TARGET" ]; then
  if [ -z "$DEPLOYED" ]; then
    # Nothing installed yet: every tag on the channel is a candidate.
    while read -r v tag; do
      [ -n "$tag" ] || continue
      NEWER="$NEWER$tag"$'\n'
    done <<< "$TAGS"
  else
    DEPLOYED_VERSION="$(bare_version "$DEPLOYED")"
    while read -r v tag; do
      [ -n "$tag" ] || continue
      if [ "$tag" = "$DEPLOYED" ]; then break; fi
      if version_gt "$v" "$DEPLOYED_VERSION"; then NEWER="$NEWER$tag"$'\n'; fi
    done <<< "$TAGS"
  fi
fi
NEWER="${NEWER%$'\n'}"
NEWER_COUNT=0
if [ -n "$NEWER" ]; then
  NEWER_COUNT="$(printf '%s\n' "$NEWER" | wc -l | tr -d ' ')"
fi
# "Available" means the channel's newest tag is strictly newer than what is
# deployed -- not merely different. Switching to an older channel (stable while
# an rc is installed) must not read as an update.
UPDATE_AVAILABLE=0
if [ -n "$TARGET" ]; then
  if [ -z "$DEPLOYED" ]; then
    UPDATE_AVAILABLE=1
  elif version_gt "$(bare_version "$TARGET")" "$(bare_version "$DEPLOYED")"; then
    UPDATE_AVAILABLE=1
  fi
fi

# ---- check mode: report and stop ------------------------------------------
if [ "$CHECK" = 1 ]; then
  if [ "$JSON" = 1 ]; then
    printf '{\n'
    printf '  "ok": %s,\n' "$([ -z "$FETCH_ERROR" ] && printf 'true' || printf 'false')"
    [ -z "$FETCH_ERROR" ] || printf '  "error": %s,\n' "$(json_string "$FETCH_ERROR")"
    printf '  "channel": %s,\n' "$(json_string "$CHANNEL")"
    printf '  "current": %s,\n' "$([ -n "$DEPLOYED" ] && json_string "$DEPLOYED" || printf 'null')"
    printf '  "currentVersion": %s,\n' "$([ -n "$DEPLOYED" ] && json_string "$(bare_version "$DEPLOYED")" || printf 'null')"
    printf '  "installedAt": %s,\n' "$([ -n "$INSTALLED_AT" ] && json_string "$INSTALLED_AT" || printf 'null')"
    printf '  "target": %s,\n' "$([ -n "$TARGET" ] && json_string "$TARGET" || printf 'null')"
    printf '  "targetVersion": %s,\n' "$([ -n "$TARGET" ] && json_string "$(bare_version "$TARGET")" || printf 'null')"
    printf '  "updateAvailable": %s,\n' "$([ "$UPDATE_AVAILABLE" = 1 ] && printf 'true' || printf 'false')"
    printf '  "newerCount": %d,\n' "$NEWER_COUNT"
    printf '  "newer": ['
    if [ -n "$NEWER" ]; then
      EMITTED=0
      while read -r tag; do
        [ -n "$tag" ] || continue
        [ "$EMITTED" -lt 20 ] || break
        [ "$EMITTED" = 0 ] || printf ', '
        printf '%s' "$(json_string "$tag")"
        EMITTED=$((EMITTED + 1))
      done <<< "$NEWER"
    fi
    printf '],\n'
    printf '  "checkedAt": %s\n' "$(json_string "$(now_iso)")"
    printf '}\n'
  else
    printf 'dsh-sync: channel=%s\n' "$CHANNEL"
    printf 'dsh-sync: deployed=%s\n' "${DEPLOYED:-none}"
    printf 'dsh-sync: newest=%s\n' "${TARGET:-none}"
    if [ -n "$FETCH_ERROR" ]; then
      printf 'dsh-sync: WARNING: %s (report may be stale)\n' "$FETCH_ERROR"
    fi
    if [ "$UPDATE_AVAILABLE" = 1 ]; then
      printf 'dsh-sync: update available: %s\n' "$TARGET"
      [ -z "$NEWER" ] || printf 'dsh-sync: newer on this channel:\n%s\n' "$(printf '%s\n' "$NEWER" | sed 's/^/  - /')"
    elif [ -n "$TARGET" ]; then
      printf 'dsh-sync: up to date\n'
    fi
  fi
  [ -z "$FETCH_ERROR" ] || exit 1
  exit 0
fi

[ -n "$TARGET" ] || { echo "dsh-sync: no tag found on channel $CHANNEL"; exit 1; }
echo "dsh-sync: channel=$CHANNEL target=$TARGET"

# ---- update mode ----------------------------------------------------------
# From here on every run leaves a progress record, whether it was started by
# the timer, the GUI, or a terminal.
mkdir -p "$STATE_DIR"
: > "$LOG_FILE"
LOG_READY=1
STARTED_AT="$(now_iso)"
STATE_DEPLOYED="$DEPLOYED"
write_status running resolving "channel $CHANNEL, target $TARGET"

# Refresh units and the profile layer first, so the smoke test below boots the
# same composition the service will run. `assets: changed=<n>` says whether the
# machine itself moved and a restart is therefore warranted.
write_status running assets "refreshing units and the profile layer"
if [ "$DRY_RUN" = 1 ]; then
  ASSETS="$("$OPS/bin/dsh-install-assets.sh" --dry-run)"
else
  ASSETS="$("$OPS/bin/dsh-install-assets.sh")"
fi
printf '%s\n' "$ASSETS"
printf '%s\n' "$ASSETS" >> "$LOG_FILE"
case "$ASSETS" in
  *"assets: changed=0"*) ASSETS_CHANGED=0 ;;
  *) ASSETS_CHANGED=1 ;;
esac

if [ "$TARGET" = "$DEPLOYED" ] && [ -L "$CURRENT" ]; then
  if [ "$DRY_RUN" = 1 ]; then
    echo "dsh-sync: already on $TARGET (dry-run)"
    FINISHED_AT="$(now_iso)"
    write_status ok done "already on $TARGET (dry-run)"
    exit 0
  fi
  if [ "$ASSETS_CHANGED" = 0 ]; then
    say "dsh-sync: already on $TARGET, nothing to do"
    FINISHED_AT="$(now_iso)"
    write_status ok done "already on $TARGET"
    exit 0
  fi
  say "dsh-sync: already on $TARGET, restarting for refreshed units/profile layer"
  write_status running restart "restarting for refreshed units/profile layer"
  systemctl --user daemon-reload
  systemctl --user restart dsh-web.service dsh-go.service
  FINISHED_AT="$(now_iso)"
  write_status ok done "refreshed units/profile layer on $TARGET"
  exit 0
fi

if [ "$DRY_RUN" = 1 ]; then
  echo "dsh-sync: dry-run, would build and deploy $TARGET (deployed: ${DEPLOYED:-none})"
  FINISHED_AT="$(now_iso)"
  write_status ok done "dry-run: would build and deploy $TARGET"
  exit 0
fi

mkdir -p "$BUILDS"
BUILD_DIR="$BUILDS/$TARGET"
if [ ! -d "$BUILD_DIR" ]; then
  say "dsh-sync: creating worktree $TARGET"
  write_status running worktree "creating worktree $TARGET"
  git -C "$UPSTREAM" worktree add --detach "$BUILD_DIR" "$TARGET"
fi

say "dsh-sync: installing deps"
write_status running deps "installing dependencies"
(cd "$BUILD_DIR" && pnpm install --frozen-lockfile --reporter=silent) || {
  say "dsh-sync: pnpm install failed, keeping ${DEPLOYED:-nothing}"
  FINISHED_AT="$(now_iso)"
  write_status failed deps "pnpm install failed; still on ${DEPLOYED:-nothing}"
  exit 1
}

say "dsh-sync: building"
write_status running build "building $TARGET"
(cd "$BUILD_DIR" && pnpm run build) || {
  say "dsh-sync: build failed, keeping ${DEPLOYED:-nothing}"
  FINISHED_AT="$(now_iso)"
  write_status failed build "build failed; still on ${DEPLOYED:-nothing}"
  exit 1
}

# The bind comes from the profile layer (0.0.0.0), so the smoke boot exercises
# the same composition the service runs; only the port differs.
say "dsh-sync: smoke test (boot on OS-assigned port)"
write_status running smoke "smoke-testing $TARGET on an OS-assigned port"
SMOKE="$(cd "$BUILD_DIR" && timeout 90 pnpm dsh web --no-open --port 0 2>&1 || true)"
echo "$SMOKE" >> "$LOG_FILE"
echo "$SMOKE" | grep -q "dsh web: http" || {
  say "dsh-sync: smoke test failed, keeping ${DEPLOYED:-nothing}"
  printf '%s\n' "$(echo "$SMOKE" | tail -n 20)" >> "$LOG_FILE"
  FINISHED_AT="$(now_iso)"
  write_status failed smoke "smoke test failed; still on ${DEPLOYED:-nothing}"
  exit 1
}
say "dsh-sync: smoke test passed"

ln -sfn "$BUILD_DIR" "$CURRENT"
printf '%s' "$TARGET" > "$REF_FILE"
say "dsh-sync: deployed $TARGET"
write_status running restart "restarting services on $TARGET"

systemctl --user daemon-reload

if systemctl --user restart dsh-web.service; then
  systemctl --user is-active dsh-web.service
  # dsh-go re-reads the launch token from the journal, and its redirect target
  # is the authority the browser used, so it only needs to be up.
  systemctl --user restart dsh-go.service     || echo "dsh-sync: WARNING: dsh-go restart failed (token-free entry may 503 until it is back)"
  say "dsh-sync: dsh-web restarted on $TARGET"
  FINISHED_AT="$(now_iso)"
  write_status ok done "deployed $TARGET"
else
  say "dsh-sync: WARNING: restart failed"
  FINISHED_AT="$(now_iso)"
  write_status failed restart "deployed $TARGET but the restart failed"
  exit 1
fi
