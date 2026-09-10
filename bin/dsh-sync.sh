#!/usr/bin/env bash
# Smart DSH updater: newest tag on a channel -> build -> smoke test -> swap.
# Never leaves the service on a broken build: failures keep `current` as-is.
set -euo pipefail

OPS="$HOME/Documents/dsh-ops"
UPSTREAM="$OPS/harness/upstream"
BUILDS="$OPS/harness/builds"
CURRENT="$OPS/harness/current"
REF_FILE="$OPS/harness/current-ref"
export PATH="$HOME/.local/share/pnpm/bin:$HOME/.local/node/bin:$PATH"

CHANNEL="rc"
DRY_RUN=0
PIN_REF=""

usage() {
  echo "usage: dsh-sync.sh [--channel stable|rc|latest] [--ref <tag>] [--dry-run]"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --channel) CHANNEL="$2"; shift 2 ;;
    --ref) PIN_REF="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1"; usage; exit 2 ;;
  esac
done

[ -d "$UPSTREAM/.git" ] || { echo "dsh-sync: no clone at $UPSTREAM (run install.sh)"; exit 1; }

git -C "$UPSTREAM" fetch --quiet origin
git -C "$UPSTREAM" fetch --quiet --tags origin

# Strip tag affixes to a bare semver-ish version: v1.2.3, dsh-v1.2.3-rc.1,
# @deepseek-ai/dsh@1.2.3-rc.1 -> 1.2.3-rc.1
bare_version() {
  local t="$1"
  t="${t##*@}"
  t="${t#dsh-}"
  t="${t#v}"
  printf '%s' "$t"
}

TARGET=""
if [ -n "$PIN_REF" ]; then
  git -C "$UPSTREAM" rev-parse --verify --quiet "refs/tags/$PIN_REF" >/dev/null \
    || { echo "dsh-sync: no such tag: $PIN_REF"; exit 1; }
  TARGET="$PIN_REF"
else
  while read -r ver tag; do
    [ -n "$tag" ] || continue
    TARGET="$tag"
    break
  done < <(git -C "$UPSTREAM" tag --list | while read -r tag; do
    [ -n "$tag" ] || continue
    v="$(bare_version "$tag")"
    case "$CHANNEL" in
      stable) [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue ;;
      rc)     [[ "$v" =~ alpha ]] && continue ;;
      latest) ;;
      *) echo "dsh-sync: unknown channel: $CHANNEL"; exit 2 ;;
    esac
    printf '%s %s\n' "$v" "$tag"
  done | sort -t' ' -k1,1Vr)
fi

[ -n "$TARGET" ] || { echo "dsh-sync: no tag found on channel $CHANNEL"; exit 1; }
echo "dsh-sync: channel=$CHANNEL target=$TARGET"

DEPLOYED=""
[ -f "$REF_FILE" ] && DEPLOYED="$(cat "$REF_FILE")"
if [ "$TARGET" = "$DEPLOYED" ] && [ -L "$CURRENT" ]; then
  echo "dsh-sync: already on $TARGET, nothing to do"
  exit 0
fi

if [ "$DRY_RUN" = 1 ]; then
  echo "dsh-sync: dry-run, would build and deploy $TARGET (deployed: ${DEPLOYED:-none})"
  exit 0
fi

mkdir -p "$BUILDS"
BUILD_DIR="$BUILDS/$TARGET"
if [ ! -d "$BUILD_DIR" ]; then
  echo "dsh-sync: creating worktree $TARGET"
  git -C "$UPSTREAM" worktree add --detach "$BUILD_DIR" "$TARGET"
fi

echo "dsh-sync: installing deps"
(cd "$BUILD_DIR" && pnpm install --frozen-lockfile --reporter=silent) || {
  echo "dsh-sync: pnpm install failed, keeping ${DEPLOYED:-nothing}"
  git -C "$UPSTREAM" worktree remove --force "$BUILD_DIR"
  exit 1
}

echo "dsh-sync: building"
(cd "$BUILD_DIR" && pnpm run build) || {
  echo "dsh-sync: build failed, keeping ${DEPLOYED:-nothing}"
  exit 1
}

echo "dsh-sync: smoke test (boot on OS-assigned port)"
SMOKE="$(cd "$BUILD_DIR" && timeout 90 pnpm dsh web --no-open --host 127.0.0.1 --port 0 2>&1 || true)"
echo "$SMOKE" | grep -q "dsh web: http" || {
  echo "dsh-sync: smoke test failed, keeping ${DEPLOYED:-nothing}"
  echo "$SMOKE" | tail -n 20
  exit 1
}
echo "dsh-sync: smoke test passed"

ln -sfn "$BUILD_DIR" "$CURRENT"
printf '%s' "$TARGET" > "$REF_FILE"
echo "dsh-sync: deployed $TARGET"

if systemctl --user restart dsh-web.service; then
  systemctl --user is-active dsh-web.service
  echo "dsh-sync: dsh-web restarted on $TARGET"
else
  echo "dsh-sync: WARNING: restart failed"
  exit 1
fi
