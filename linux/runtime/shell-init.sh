# shellcheck shell=bash
# Shell integration for the account-wide Clash SSH reverse proxy.

proxy_on() { . "$HOME/.config/clash-ssh-proxy/proxy-on.sh"; }
proxy_off() { . "$HOME/.config/clash-ssh-proxy/proxy-off.sh"; }
proxy_status() {
    proxy_on || return 1
    curl -sS -o /dev/null --connect-timeout 3 --max-time 8 \
      -w 'Clash SSH proxy: HTTP %{http_code}, peer %{remote_ip}\n' \
      -x "$CLASH_SSH_PROXY" https://www.google.com/generate_204
}

proxy_on
