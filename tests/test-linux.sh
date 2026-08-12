#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_home="$(mktemp -d)"
trap 'rm -rf -- "$test_home"' EXIT

cat > "$test_home/.bashrc" <<'EOF'
case $- in
    *i*) ;;
    *) return ;;
esac
export USER_SETTING=kept
EOF

cat > "$test_home/.profile" <<'EOF'
export PROFILE_SETTING=kept
EOF

HOME="$test_home" USER=tester bash "$repo_dir/linux/install-linux.sh" \
  --remote-proxy-port 19000 \
  --no-proxy-extra intranet.example.com

HOME="$test_home" USER=tester bash "$repo_dir/linux/install-linux.sh" \
  --remote-proxy-port 19000 \
  --no-proxy-extra intranet.example.com

[[ "$(grep -c '^# >>> clash-ssh-proxy >>>$' "$test_home/.bashrc")" -eq 1 ]]
[[ "$(grep -c '^# >>> clash-ssh-proxy >>>$' "$test_home/.profile")" -eq 1 ]]
grep -q '^export USER_SETTING=kept$' "$test_home/.bashrc"
grep -q '^export PROFILE_SETTING=kept$' "$test_home/.profile"
grep -q "CLASH_SSH_PROXY='http://127.0.0.1:19000'" \
  "$test_home/.config/clash-ssh-proxy/config.sh"
grep -q 'intranet.example.com' "$test_home/.config/clash-ssh-proxy/config.sh"

HOME="$test_home" bash -c '
  . "$HOME/.config/clash-ssh-proxy/shell-init.sh"
  [[ "$http_proxy" == "http://127.0.0.1:19000" ]]
  proxy_off
  [[ -z "${http_proxy+x}" ]]
'

fake_bin="$test_home/fake-bin"
curl_log="$test_home/curl.log"
mkdir -p "$fake_bin"
cat > "$fake_bin/ss" <<'EOF'
#!/usr/bin/env bash
printf 'LISTEN 0 128 127.0.0.1:19000 0.0.0.0:*\n'
EOF
cat > "$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
if [[ "${FAKE_CURL_MODE:-fallback}" == 'all-fail' ]]; then
  exit 35
fi
case "$*" in
  *www.gstatic.com*) exit 35 ;;
  *cp.cloudflare.com*) exit 0 ;;
  *) exit 35 ;;
esac
EOF
chmod 700 "$fake_bin/ss" "$fake_bin/curl"

: > "$curl_log"
HOME="$test_home" PATH="$fake_bin:$PATH" CURL_LOG="$curl_log" \
  bash "$test_home/.config/clash-ssh-proxy/check-linux.sh" --quiet
grep -q 'www.gstatic.com/generate_204' "$curl_log"
grep -q 'cp.cloudflare.com/generate_204' "$curl_log"
! grep -q 'www.google.com/generate_204' "$curl_log"

if HOME="$test_home" PATH="$fake_bin:$PATH" CURL_LOG="$curl_log" \
  FAKE_CURL_MODE=all-fail \
  bash "$test_home/.config/clash-ssh-proxy/check-linux.sh" --quiet; then
  echo 'All failed health endpoints should fail the proxy check' >&2
  exit 1
fi

HOME="$test_home" PATH="$fake_bin:$PATH" CURL_LOG="$curl_log" \
  bash -c '. "$HOME/.config/clash-ssh-proxy/shell-init.sh"; proxy_status'

HOME="$test_home" bash "$test_home/.config/clash-ssh-proxy/uninstall-linux.sh" --purge
! grep -q '^# >>> clash-ssh-proxy >>>$' "$test_home/.bashrc"
! grep -q '^# >>> clash-ssh-proxy >>>$' "$test_home/.profile"
grep -q '^export USER_SETTING=kept$' "$test_home/.bashrc"
grep -q '^export PROFILE_SETTING=kept$' "$test_home/.profile"
[[ ! -e "$test_home/.config/clash-ssh-proxy" ]]

echo "Linux installer tests passed"
