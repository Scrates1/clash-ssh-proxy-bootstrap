#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
test_home="$test_root/main"
mkdir -p "$test_home/dotfiles"
trap 'rm -rf -- "$test_root"' EXIT

cat > "$test_home/dotfiles/bashrc" <<'EOF'
case $- in
    *i*) ;;
    *) return ;;
esac
export USER_SETTING=kept
EOF
ln -s "dotfiles/bashrc" "$test_home/.bashrc"

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
[[ -L "$test_home/.bashrc" ]]
grep -q "CLASH_SSH_PROXY='http://127.0.0.1:19000'" \
  "$test_home/.config/clash-ssh-proxy/config.sh"
grep -q 'intranet.example.com' "$test_home/.config/clash-ssh-proxy/config.sh"

HOME="$test_home" bash -c '
  . "$HOME/.config/clash-ssh-proxy/shell-init.sh"
  [[ "$http_proxy" == "http://127.0.0.1:19000" ]]
  [[ "$NODE_USE_ENV_PROXY" == "1" ]]
  proxy_off
  [[ -z "${http_proxy+x}" ]]
  [[ -z "${NODE_USE_ENV_PROXY+x}" ]]
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

cat > "$test_home/dotfiles/untouched-profile" <<'EOF'
export UNTOUCHED_SETTING=kept
EOF
ln -s "dotfiles/untouched-profile" "$test_home/.bash_profile"
ln -s 'missing-login-file' "$test_home/.bash_login"

HOME="$test_home" bash "$test_home/.config/clash-ssh-proxy/uninstall-linux.sh" --purge
! grep -q '^# >>> clash-ssh-proxy >>>$' "$test_home/.bashrc"
! grep -q '^# >>> clash-ssh-proxy >>>$' "$test_home/.profile"
grep -q '^export USER_SETTING=kept$' "$test_home/.bashrc"
grep -q '^export PROFILE_SETTING=kept$' "$test_home/.profile"
[[ -L "$test_home/.bashrc" ]]
[[ -L "$test_home/.bash_profile" ]]
[[ -L "$test_home/.bash_login" ]]
grep -q '^export UNTOUCHED_SETTING=kept$' "$test_home/.bash_profile"
[[ ! -e "$test_home/.config/clash-ssh-proxy" ]]

malformed_home="$test_root/malformed"
mkdir -p "$malformed_home"
printf '%s\n' 'export BASHRC_SETTING=kept' > "$malformed_home/.bashrc"
printf '%s\n' 'export PROFILE_SETTING=kept' > "$malformed_home/.profile"
HOME="$malformed_home" USER=tester bash "$repo_dir/linux/install-linux.sh" \
  --remote-proxy-port 19001
printf '%s\n' '# <<< clash-ssh-proxy <<<' >> "$malformed_home/.profile"
if HOME="$malformed_home" bash \
  "$malformed_home/.config/clash-ssh-proxy/uninstall-linux.sh" --purge; then
  echo 'Malformed managed blocks should make uninstall fail closed' >&2
  exit 1
fi
grep -q '^# >>> clash-ssh-proxy >>>$' "$malformed_home/.bashrc"
grep -q '^# <<< clash-ssh-proxy <<<$' "$malformed_home/.profile"
[[ -d "$malformed_home/.config/clash-ssh-proxy" ]]

dangling_home="$test_root/dangling"
mkdir -p "$dangling_home"
ln -s 'missing-bashrc' "$dangling_home/.bashrc"
printf '%s\n' 'export PROFILE_SETTING=kept' > "$dangling_home/.profile"
if HOME="$dangling_home" USER=tester bash "$repo_dir/linux/install-linux.sh"; then
  echo 'A dangling startup-file link should be rejected' >&2
  exit 1
fi
[[ -L "$dangling_home/.bashrc" ]]

backup_link_home="$test_root/backup-link"
mkdir -p "$backup_link_home/.config/clash-ssh-proxy/backups"
printf '%s\n' 'export BASHRC_SETTING=kept' > "$backup_link_home/.bashrc"
printf '%s\n' 'export PROFILE_SETTING=kept' > "$backup_link_home/.profile"
printf '%s\n' 'backup-sentinel' > "$backup_link_home/sentinel"
ln -s "$backup_link_home/sentinel" \
  "$backup_link_home/.config/clash-ssh-proxy/backups/bashrc.original"
if HOME="$backup_link_home" USER=tester bash "$repo_dir/linux/install-linux.sh"; then
  echo 'A symbolic-link backup file should be rejected' >&2
  exit 1
fi
grep -q '^backup-sentinel$' "$backup_link_home/sentinel"
grep -q '^export BASHRC_SETTING=kept$' "$backup_link_home/.bashrc"

managed_link_home="$test_root/managed-link"
mkdir -p "$managed_link_home/.config/clash-ssh-proxy"
printf '%s\n' 'export BASHRC_SETTING=kept' > "$managed_link_home/.bashrc"
printf '%s\n' 'export PROFILE_SETTING=kept' > "$managed_link_home/.profile"
printf '%s\n' 'managed-sentinel' > "$managed_link_home/sentinel"
ln -s "$managed_link_home/sentinel" \
  "$managed_link_home/.config/clash-ssh-proxy/config.sh"
if HOME="$managed_link_home" USER=tester bash "$repo_dir/linux/install-linux.sh"; then
  echo 'A symbolic-link managed output should be rejected' >&2
  exit 1
fi
grep -q '^managed-sentinel$' "$managed_link_home/sentinel"
grep -q '^export BASHRC_SETTING=kept$' "$managed_link_home/.bashrc"

echo "Linux installer tests passed"
