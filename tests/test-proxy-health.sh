#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d /tmp/clash-proxy-health.XXXXXX)"
fixture_pid=''
cleanup_fixture() {
    if [[ -n "$fixture_pid" ]]; then
        kill "$fixture_pid" 2>/dev/null || true
        wait "$fixture_pid" 2>/dev/null || true
    fi
    case "$fixture_root" in /tmp/clash-proxy-health.*) rm -rf -- "$fixture_root" ;; *) return 1 ;; esac
}
trap cleanup_fixture EXIT

openssl req -x509 -newkey rsa:2048 -nodes -subj '/CN=www.gstatic.com' \
    -keyout "$fixture_root/key.pem" -out "$fixture_root/cert.pem" -days 1 >/dev/null 2>&1
python3 "$repo_dir/tests/proxy-health-fixture.py" "$fixture_root" "$repo_dir" &
fixture_pid=$!
for (( attempt=0; attempt<50; attempt++ )); do
    [[ -s "$fixture_root/ports.json" ]] && break
    sleep 0.1
done
[[ -s "$fixture_root/ports.json" ]] || { echo 'Health fixture did not start' >&2; exit 1; }
health_port="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["health"])' "$fixture_root/ports.json")"
bad_port="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["bad"])' "$fixture_root/ports.json")"
good_port="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["good"])' "$fixture_root/ports.json")"
real_curl="$(command -v curl)"
mkdir -p "$fixture_root/bin" "$fixture_root/home/.config/clash-ssh-proxy"
cat > "$fixture_root/bin/curl" <<'EOF'
#!/usr/bin/env bash
exec "$REAL_CURL" --insecure \
    --connect-to "www.gstatic.com:443:127.0.0.1:$HEALTH_PORT" \
    --connect-to "cp.cloudflare.com:443:127.0.0.1:$HEALTH_PORT" \
    --connect-to "www.google.com:443:127.0.0.1:$HEALTH_PORT" "$@"
EOF
chmod 700 "$fixture_root/bin/curl"
export REAL_CURL="$real_curl" HEALTH_PORT="$health_port"
cp "$repo_dir/linux/runtime/proxy-on.sh" "$fixture_root/home/.config/clash-ssh-proxy/"
bypass='www.gstatic.com,cp.cloudflare.com,www.google.com'
write_config() {
    printf "CLASH_SSH_PROXY='http://127.0.0.1:%s'\nCLASH_SSH_NO_PROXY='%s'\n" \
        "$1" "$bypass" > "$fixture_root/home/.config/clash-ssh-proxy/config.sh"
}
write_config "$bad_port"
if env HOME="$fixture_root/home" PATH="$fixture_root/bin:$PATH" \
    bash "$repo_dir/linux/check-linux.sh" --quiet; then
    echo 'NO_PROXY made an unusable proxy pass the Linux health check' >&2
    exit 1
fi
if env PATH="$fixture_root/bin:$PATH" NO_PROXY="$bypass" no_proxy="$bypass" \
    sh "$fixture_root/manager-bad.sh"; then
    echo 'NO_PROXY made an unusable proxy pass the manager health check' >&2
    exit 1
fi
[[ ! -s "$fixture_root/health.log" ]]
[[ "$(wc -l < "$fixture_root/bad-proxy.log")" -eq 6 ]]
write_config "$good_port"
env HOME="$fixture_root/home" PATH="$fixture_root/bin:$PATH" bash "$repo_dir/linux/check-linux.sh" --quiet
env PATH="$fixture_root/bin:$PATH" NO_PROXY="$bypass" no_proxy="$bypass" sh "$fixture_root/manager-good.sh"
[[ "$(wc -l < "$fixture_root/good-proxy.log")" -eq 2 ]]

# Preserve unrelated keys, remove both plain and restricted matching entries,
# and verify idempotency in a home directory containing spaces.
cleanup_home="$fixture_root/cleanup home with spaces"
mkdir -p "$cleanup_home/.ssh"
printf '%s\n' 'ssh-ed25519 RUZHSA== preserved' 'ssh-ed25519 QUJDRA== managed' \
    'command="echo test fixture" ssh-ed25519 QUJDRA== restricted' \
    'ssh-rsa UVdFUg== preserved' > "$cleanup_home/.ssh/authorized_keys"
printf '%s\n' 'ssh-ed25519 RUZHSA== preserved' 'ssh-rsa UVdFUg== preserved' > "$fixture_root/expected-keys"
env HOME="$cleanup_home" sh "$fixture_root/cleanup.sh" >/dev/null
cmp "$fixture_root/expected-keys" "$cleanup_home/.ssh/authorized_keys"
env HOME="$cleanup_home" sh "$fixture_root/cleanup.sh" >/dev/null
cmp "$fixture_root/expected-keys" "$cleanup_home/.ssh/authorized_keys"
echo 'Proxy health and remote key cleanup tests passed'
