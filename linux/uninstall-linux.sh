#!/usr/bin/env bash
set -euo pipefail

purge=false
case "${1:-}" in
    "") ;;
    --purge) purge=true ;;
    -h|--help)
        echo "Usage: $0 [--purge]"
        exit 0
        ;;
    *)
        echo "Usage: $0 [--purge]" >&2
        exit 2
        ;;
esac

config_dir="$HOME/.config/clash-ssh-proxy"

remove_proxy_blocks() {
    local startup_file="$1"
    local clean_file
    [[ -e "$startup_file" ]] || return 0
    clean_file="$(mktemp "${startup_file}.clean.XXXXXX")"
    awk '
        BEGIN { skip = 0 }
        $0 == "# >>> clash-ssh-proxy >>>" ||
        $0 == "# >>> Codex Clash proxy >>>" { skip = 1; next }
        $0 == "# <<< clash-ssh-proxy <<<" ||
        $0 == "# <<< Codex Clash proxy <<<" { skip = 0; next }
        !skip { print }
        END { if (skip) exit 43 }
    ' "$startup_file" > "$clean_file"
    chmod --reference="$startup_file" "$clean_file"
    mv -f -- "$clean_file" "$startup_file"
}

remove_proxy_blocks "$HOME/.bashrc"
remove_proxy_blocks "$HOME/.profile"
remove_proxy_blocks "$HOME/.bash_profile"
remove_proxy_blocks "$HOME/.bash_login"

if [[ -d "$config_dir" && ! -L "$config_dir" ]]; then
    if [[ "$purge" == true ]]; then
        rm -rf -- "$config_dir"
        echo "Removed $config_dir"
    else
        archive="$HOME/.config/clash-ssh-proxy.removed-$(date +%Y%m%d-%H%M%S)"
        [[ ! -e "$archive" ]] || archive="$archive-$$"
        mv -- "$config_dir" "$archive"
        echo "Archived configuration at $archive"
    fi
fi

echo "Removed clash-ssh-proxy shell integration"
