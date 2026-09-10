#!/usr/bin/env bash
# Follow the dsh-ops services (the GUI and the token-free entry).
set -uo pipefail
exec journalctl --user -u dsh-web -u dsh-go -f "$@"
