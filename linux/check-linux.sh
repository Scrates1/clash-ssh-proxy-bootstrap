#!/usr/bin/env bash
set -euo pipefail

quiet=false
if [[ "${1:-}" == "--quiet" ]]; then
    quiet=true
elif [[ $# -gt 0 ]]; then
    echo "Usage: $0 [--quiet]" >&2
    exit 2
fi

config_dir="$HOME/.config/clash-ssh-proxy"
[[ -r "$config_dir/proxy-on.sh" ]] || {
    echo "Missing $config_dir/proxy-on.sh" >&2
    exit 1
}

# shellcheck disable=SC1091
. "$config_dir/proxy-on.sh"

if command -v ss >/dev/null 2>&1; then
    port="${CLASH_SSH_PROXY##*:}"
    ss -ltn | grep -qE "127[.]0[.]0[.]1:${port}[[:space:]]"
fi

curl -fsS -o /dev/null --connect-timeout 3 --max-time 12 \
  -x "$CLASH_SSH_PROXY" https://www.google.com/generate_204

if [[ "$quiet" == false ]]; then
    printf 'Clash SSH proxy OK: %s\n' "$CLASH_SSH_PROXY"
fi
