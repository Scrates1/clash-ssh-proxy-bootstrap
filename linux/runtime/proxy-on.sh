# shellcheck shell=sh
# Enable the account-wide proxy in the current shell.

_clash_ssh_config="$HOME/.config/clash-ssh-proxy/config.sh"
if [ ! -r "$_clash_ssh_config" ]; then
    echo "clash-ssh-proxy: missing $_clash_ssh_config" >&2
    unset _clash_ssh_config
    return 1 2>/dev/null || exit 1
fi

. "$_clash_ssh_config"
unset _clash_ssh_config

export CLASH_SSH_PROXY
export http_proxy="$CLASH_SSH_PROXY"
export https_proxy="$CLASH_SSH_PROXY"
export HTTP_PROXY="$CLASH_SSH_PROXY"
export HTTPS_PROXY="$CLASH_SSH_PROXY"
export ALL_PROXY="$CLASH_SSH_PROXY"
export all_proxy="$CLASH_SSH_PROXY"
export NO_PROXY="$CLASH_SSH_NO_PROXY"
export no_proxy="$CLASH_SSH_NO_PROXY"
