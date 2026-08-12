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

health_urls=(
  'https://www.gstatic.com/generate_204'
  'https://cp.cloudflare.com/generate_204'
  'https://www.google.com/generate_204'
)

working_url=''
for health_url in "${health_urls[@]}"; do
    if curl -fsS -o /dev/null --connect-timeout 2 --max-time 4 \
      -x "$CLASH_SSH_PROXY" "$health_url" 2>/dev/null; then
        working_url="$health_url"
        break
    fi
done

if [[ -z "$working_url" ]]; then
    if [[ "$quiet" == false ]]; then
        echo 'Clash SSH proxy unavailable: all health check endpoints failed' >&2
    fi
    exit 1
fi

if [[ "$quiet" == false ]]; then
    printf 'Clash SSH proxy OK: %s (via %s)\n' "$CLASH_SSH_PROXY" "$working_url"
fi
