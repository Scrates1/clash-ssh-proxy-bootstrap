# shellcheck shell=bash
# Shell integration for the account-wide Clash SSH reverse proxy.

proxy_on() { . "$HOME/.config/clash-ssh-proxy/proxy-on.sh"; }
proxy_off() { . "$HOME/.config/clash-ssh-proxy/proxy-off.sh"; }
proxy_status() {
    "$HOME/.config/clash-ssh-proxy/check-linux.sh"
}

proxy_on
