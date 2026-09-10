#!/usr/bin/env bash
# Install, inspect, or remove the model-provider credential for this host's dsh.
#
# The Web GUI's first-run step ("Add an API key to get started") appears whenever
# no provider can serve requests. That key is the operator's own long-lived
# platform key — not a session secret and not rotated — and dsh keeps it on the
# host, so the step never renders again once one usable provider exists.
# @deepseek-ai/dsh-credentials-local resolves a reference in this order:
#
#   inherited process environment    (read-only, wins)
#   > $DSH_HOME/.credentials.yaml    (the store the Models page writes)
#   > $DSH_HOME/.env                 (this script)
#   > <invocation cwd>/.env
#
# Writing the harness-home .env keeps the secret out of the browser and out of
# the repo, survives every sync (DSH_HOME is never touched), and still lets a
# key stored later from the Models page win — the store outranks that fallback.
#
# usage: dsh-set-key.sh [--ref NAME] [--stdin] [--unset] [--show]
#                       [--no-restart] [--dry-run]
#   (no arguments)  take the value from $DEEPSEEK_API_KEY when set, else prompt
#                   for it twice with the input hidden
#   --stdin         read the value from stdin instead of prompting
#   --show          report which source currently provides the reference
#   --unset         remove the value this script manages
#   --no-restart    do not restart dsh-web afterwards
set -euo pipefail

DSH_HOME_DIR="${DSH_HOME:-$HOME/.dsh}"
ENV_FILE="$DSH_HOME_DIR/.env"
CRED_FILE="$DSH_HOME_DIR/.credentials.yaml"
MARKER='# dsh-ops:provider-key'
OPS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REF='DEEPSEEK_API_KEY'
USE_STDIN=0
MODE='set'
NO_RESTART=0
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --ref) REF="$2"; shift 2 ;;
    --stdin) USE_STDIN=1; shift ;;
    --show) MODE='show'; shift ;;
    --unset) MODE='unset'; shift ;;
    --no-restart) NO_RESTART=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '21,31p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

case "$REF" in
  ''|*[!A-Za-z0-9_]*) echo "dsh-set-key: --ref must look like ENV_VAR_NAME" >&2; exit 2 ;;
esac

run() {
  if [ "$DRY_RUN" = 1 ]; then echo "+ $*"; else "$@"; fi
}

# Byte length of a secret, for reporting without ever printing it.
value_length() {
  printf '%s' "$1" | wc -c | tr -d ' '
}

# Value from the process environment, stdin, or the hidden prompt.
read_value() {
  local from_env
  from_env="$(printenv "$REF" 2>/dev/null || true)"
  if [ -n "$from_env" ]; then printf '%s' "$from_env"; return 0; fi
  if [ "$USE_STDIN" = 1 ]; then
    local line
    IFS= read -r line || true
    printf '%s' "$line"
    return 0
  fi
  if [ ! -t 0 ]; then
    echo "dsh-set-key: no terminal for the hidden prompt; use --stdin or set $REF" >&2
    exit 2
  fi
  local first second
  printf 'Paste the %s value (input hidden): ' "$REF" >&2
  IFS= read -rs first; printf '\n' >&2
  printf 'Repeat it: ' >&2
  IFS= read -rs second; printf '\n' >&2
  if [ "$first" != "$second" ]; then
    echo "dsh-set-key: the two values differ" >&2
    exit 2
  fi
  printf '%s' "$first"
}

# Rewrite the harness-home .env with exactly one managed entry for $REF.
write_env() {
  local value="$1" tmp
  if [ "$DRY_RUN" = 1 ]; then
    echo "+ rewrite $ENV_FILE (mode 600): $MARKER and $REF=<$(value_length "$value") bytes>"
    return 0
  fi
  mkdir -p "$DSH_HOME_DIR"
  tmp="$(mktemp "$ENV_FILE.XXXXXX")"
  if [ -f "$ENV_FILE" ]; then
    grep -v -e "^$MARKER" -e "^$REF=" "$ENV_FILE" > "$tmp" || true
  fi
  {
    printf '%s — managed by dsh-ops/bin/dsh-set-key.sh; --unset removes it\n' "$MARKER"
    printf '%s=%s\n' "$REF" "$value"
  } >> "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$ENV_FILE"
}

remove_env_entry() {
  local tmp
  if [ ! -f "$ENV_FILE" ] || ! grep -q -e "^$MARKER" -e "^$REF=" "$ENV_FILE"; then
    echo "dsh-set-key: nothing of ours in $ENV_FILE"
    return 1
  fi
  if [ "$DRY_RUN" = 1 ]; then
    echo "+ remove the $REF entry from $ENV_FILE"
    return 0
  fi
  tmp="$(mktemp "$ENV_FILE.XXXXXX")"
  grep -v -e "^$MARKER" -e "^$REF=" "$ENV_FILE" > "$tmp" || true
  chmod 600 "$tmp"
  mv "$tmp" "$ENV_FILE"
}

# What each source currently provides, without printing a value.
show_sources() {
  local inherited stored=no fallback=no
  inherited="$(printenv "$REF" 2>/dev/null || true)"
  if [ -f "$CRED_FILE" ] && grep -qE "^  $REF: ." "$CRED_FILE"; then stored=yes; fi
  if [ -f "$ENV_FILE" ] && grep -qE "^$REF=" "$ENV_FILE"; then fallback=yes; fi
  echo "$REF sources — the first match is what dsh uses:"
  if [ -n "$inherited" ]; then
    echo "  1. inherited environment : configured here ($(value_length "$inherited") bytes), read-only to dsh"
  else
    echo "  1. inherited environment : not set in this shell"
  fi
  if [ "$stored" = yes ]; then
    echo "  2. .credentials.yaml refs: configured"
  else
    echo "  2. .credentials.yaml refs: not set"
  fi
  if [ "$fallback" = yes ]; then
    echo "  3. $ENV_FILE : configured"
  else
    echo "  3. $ENV_FILE : not set"
  fi
}

restart_web() {
  if ! command -v systemctl >/dev/null 2>&1 || ! systemctl --user cat dsh-web.service >/dev/null 2>&1; then
    echo "dsh-set-key: no dsh-web.service here — restart the harness so it reads $ENV_FILE" >&2
    return 0
  fi
  local since i
  since="$(date '+%Y-%m-%d %H:%M:%S')"
  systemctl --user restart dsh-web.service
  for i in $(seq 1 45); do
    if journalctl --user -u dsh-web --since "$since" --no-pager 2>/dev/null | grep -q "dsh web: http"; then
      echo "dsh-set-key: dsh-web restarted and serving"
      if [ -x "$OPS/bin/dsh-url.sh" ]; then "$OPS/bin/dsh-url.sh"; fi
      return 0
    fi
    sleep 1
  done
  echo "dsh-set-key: warning: dsh-web printed no startup line within 45s; check journalctl --user -u dsh-web" >&2
}

case "$MODE" in
  show)
    show_sources
    exit 0
    ;;
  unset)
    remove_env_entry || true
    echo "dsh-set-key: removed the managed $REF entry"
    if [ "$NO_RESTART" = 0 ] && [ "$DRY_RUN" = 0 ]; then restart_web; fi
    exit 0
    ;;
esac

value="$(read_value)"
if [ -z "$value" ]; then
  echo "dsh-set-key: empty value; nothing written" >&2
  exit 2
fi
case "$value" in
  *[[:space:]]*) echo "dsh-set-key: the value contains whitespace; check the paste" >&2; exit 2 ;;
esac

write_env "$value"
echo "dsh-set-key: $REF stored in $ENV_FILE (mode 600, $(value_length "$value") bytes)"
echo "dsh-set-key: a key stored later from the Models page outranks this fallback"
if [ "$NO_RESTART" = 0 ] && [ "$DRY_RUN" = 0 ]; then restart_web; fi
