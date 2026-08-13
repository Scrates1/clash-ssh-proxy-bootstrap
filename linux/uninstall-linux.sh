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

if [[ -L "$config_dir" || ( -e "$config_dir" && ! -d "$config_dir" ) ]]; then
    echo "Refusing to uninstall through a non-directory managed path: $config_dir" >&2
    exit 1
fi

resolve_startup_file() {
    local startup_file="$1"
    local resolved_file
    if [[ -L "$startup_file" ]]; then
        resolved_file="$(readlink -f -- "$startup_file")" || {
            echo "Unable to resolve startup-file link: $startup_file" >&2
            return 1
        }
        [[ -n "$resolved_file" && -f "$resolved_file" ]] || {
            echo "Startup-file link is dangling or not a regular file: $startup_file" >&2
            return 1
        }
        printf '%s\n' "$resolved_file"
        return
    fi
    if [[ -e "$startup_file" && ! -f "$startup_file" ]]; then
        echo "Startup path is not a regular file: $startup_file" >&2
        return 1
    fi
    printf '%s\n' "$startup_file"
}

filter_proxy_blocks() {
    local source_file="$1"
    local output_file="$2"
    awk '
        BEGIN { skip = 0; opens = 0; closes = 0 }
        $0 == "# >>> clash-ssh-proxy >>>" ||
        $0 == "# >>> Codex Clash proxy >>>" {
            if (skip) exit 41
            skip = 1
            opens++
            next
        }
        $0 == "# <<< clash-ssh-proxy <<<" ||
        $0 == "# <<< Codex Clash proxy <<<" {
            if (!skip) exit 42
            skip = 0
            closes++
            next
        }
        !skip { print }
        END { if (skip || opens != closes) exit 43 }
    ' "$source_file" > "$output_file"
}

has_proxy_marker() {
    local source_file="$1"
    grep -Eq '^# >>> (clash-ssh-proxy|Codex Clash proxy) >>>$|^# <<< (clash-ssh-proxy|Codex Clash proxy) <<<$' "$source_file"
}

validate_startup_file() {
    local startup_file="$1"
    local resolved_file
    [[ -e "$startup_file" || -L "$startup_file" ]] || return 0
    [[ -f "$startup_file" ]] || return 0
    resolved_file="$(resolve_startup_file "$startup_file")"
    has_proxy_marker "$resolved_file" || return 0
    if ! filter_proxy_blocks "$resolved_file" /dev/null; then
        echo "Refusing to edit malformed managed block in $startup_file" >&2
        return 1
    fi
}

remove_proxy_blocks() {
    local startup_file="$1"
    local resolved_file
    local clean_file
    [[ -e "$startup_file" || -L "$startup_file" ]] || return 0
    [[ -f "$startup_file" ]] || return 0
    resolved_file="$(resolve_startup_file "$startup_file")"
    has_proxy_marker "$resolved_file" || return 0
    clean_file="$(mktemp "${resolved_file}.clean.XXXXXX")"
    if ! filter_proxy_blocks "$resolved_file" "$clean_file"; then
        rm -f -- "$clean_file"
        echo "Refusing to edit malformed managed block in $startup_file" >&2
        return 1
    fi
    chmod --reference="$resolved_file" "$clean_file"
    mv -f -- "$clean_file" "$resolved_file"
}

startup_files=("$HOME/.bashrc" "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.bash_login")
for startup_file in "${startup_files[@]}"; do
    validate_startup_file "$startup_file"
done
for startup_file in "${startup_files[@]}"; do
    remove_proxy_blocks "$startup_file"
done

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
