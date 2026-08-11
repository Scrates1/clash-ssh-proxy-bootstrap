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

HOME="$test_home" bash "$test_home/.config/clash-ssh-proxy/uninstall-linux.sh" --purge
! grep -q '^# >>> clash-ssh-proxy >>>$' "$test_home/.bashrc"
! grep -q '^# >>> clash-ssh-proxy >>>$' "$test_home/.profile"
grep -q '^export USER_SETTING=kept$' "$test_home/.bashrc"
grep -q '^export PROFILE_SETTING=kept$' "$test_home/.profile"
[[ ! -e "$test_home/.config/clash-ssh-proxy" ]]

echo "Linux installer tests passed"
