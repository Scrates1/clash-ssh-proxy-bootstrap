#!/usr/bin/env bash
set -euo pipefail

remote_proxy_port=17897
no_proxy_extra=""

usage() {
    cat <<'EOF'
Usage: install-linux.sh [options]

Options:
  --remote-proxy-port PORT   Loopback proxy port on this Linux host (default: 17897)
  --no-proxy-extra LIST      Additional comma-separated NO_PROXY entries
  -h, --help                 Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --remote-proxy-port)
            [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
            remote_proxy_port="$2"
            shift 2
            ;;
        --no-proxy-extra)
            [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
            no_proxy_extra="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[[ "$remote_proxy_port" =~ ^[0-9]+$ ]] || {
    echo "Remote proxy port must be numeric" >&2
    exit 2
}
(( remote_proxy_port >= 1 && remote_proxy_port <= 65535 )) || {
    echo "Remote proxy port must be between 1 and 65535" >&2
    exit 2
}
[[ "$no_proxy_extra" =~ ^[A-Za-z0-9.,_:/-]*$ ]] || {
    echo "NO_PROXY entries contain unsupported characters" >&2
    exit 2
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
runtime_dir="$script_dir/runtime"
config_dir="$HOME/.config/clash-ssh-proxy"
backup_dir="$config_dir/backups"

for required in proxy-on.sh proxy-off.sh shell-init.sh README.md; do
    [[ -f "$runtime_dir/$required" ]] || {
        echo "Missing runtime file: $runtime_dir/$required" >&2
        exit 1
    }
done

for managed_dir in "$config_dir" "$backup_dir"; do
    if [[ -L "$managed_dir" || ( -e "$managed_dir" && ! -d "$managed_dir" ) ]]; then
        echo "Managed path must be a regular directory, not a link or file: $managed_dir" >&2
        exit 1
    fi
done

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

backup_once() {
    local source_file="$1"
    local backup_file="$2"
    if [[ -L "$backup_file" ]]; then
        echo "Refusing to use a symbolic link as a backup file: $backup_file" >&2
        return 1
    fi
    if [[ ! -e "$backup_file" ]]; then
        if [[ -e "$source_file" || -L "$source_file" ]]; then
            local resolved_source
            resolved_source="$(resolve_startup_file "$source_file")"
            cp -p -- "$resolved_source" "$backup_file"
        else
            : > "$backup_file"
            chmod 600 "$backup_file"
        fi
    fi
}

validate_startup_file() {
    local startup_file="$1"
    local resolved_file
    [[ -e "$startup_file" || -L "$startup_file" ]] || return 0
    resolved_file="$(resolve_startup_file "$startup_file")"
    if ! remove_proxy_blocks "$resolved_file" /dev/null; then
        echo "Refusing to edit malformed managed block in $startup_file" >&2
        return 1
    fi
}

remove_proxy_blocks() {
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
        END {
            if (skip || opens != closes) exit 43
        }
    ' "$source_file" > "$output_file"
}

update_startup_file() {
    local startup_file="$1"
    local resolved_file
    local clean_file
    local final_file

    if [[ ! -e "$startup_file" ]]; then
        : > "$startup_file"
        chmod 644 "$startup_file"
    fi

    resolved_file="$(resolve_startup_file "$startup_file")"

    clean_file="$(mktemp "${resolved_file}.clean.XXXXXX")"
    final_file="$(mktemp "${resolved_file}.new.XXXXXX")"

    if ! remove_proxy_blocks "$resolved_file" "$clean_file"; then
        rm -f -- "$clean_file" "$final_file"
        echo "Refusing to edit malformed managed block in $startup_file" >&2
        exit 1
    fi

    {
        printf '%s\n' '# >>> clash-ssh-proxy >>>'
        printf '%s\n' 'if [ -r "$HOME/.config/clash-ssh-proxy/shell-init.sh" ]; then'
        printf '%s\n' '    . "$HOME/.config/clash-ssh-proxy/shell-init.sh"'
        printf '%s\n' 'fi'
        printf '%s\n\n' '# <<< clash-ssh-proxy <<<'
        cat -- "$clean_file"
    } > "$final_file"

    chmod --reference="$resolved_file" "$final_file"
    mv -f -- "$final_file" "$resolved_file"
    rm -f -- "$clean_file"
}

login_file="$HOME/.profile"
if [[ -e "$HOME/.bash_profile" || -L "$HOME/.bash_profile" ]]; then
    login_file="$HOME/.bash_profile"
elif [[ -e "$HOME/.bash_login" || -L "$HOME/.bash_login" ]]; then
    login_file="$HOME/.bash_login"
fi
validate_startup_file "$HOME/.bashrc"
if [[ "$login_file" != "$HOME/.bashrc" ]]; then
    validate_startup_file "$login_file"
fi
install -d -m 700 "$config_dir" "$backup_dir"
for managed_file in \
    proxy-on.sh proxy-off.sh shell-init.sh README.md check-linux.sh \
    uninstall-linux.sh config.sh; do
    managed_path="$config_dir/$managed_file"
    if [[ -L "$managed_path" || ( -e "$managed_path" && ! -f "$managed_path" ) ]]; then
        echo "Managed output must be a regular file, not a link: $managed_path" >&2
        exit 1
    fi
done
backup_once "$HOME/.bashrc" "$backup_dir/bashrc.original"
backup_once "$login_file" "$backup_dir/$(basename "$login_file").original"

install -m 600 "$runtime_dir/proxy-on.sh" "$config_dir/proxy-on.sh"
install -m 600 "$runtime_dir/proxy-off.sh" "$config_dir/proxy-off.sh"
install -m 600 "$runtime_dir/shell-init.sh" "$config_dir/shell-init.sh"
install -m 600 "$runtime_dir/README.md" "$config_dir/README.md"
install -m 700 "$script_dir/check-linux.sh" "$config_dir/check-linux.sh"
install -m 700 "$script_dir/uninstall-linux.sh" "$config_dir/uninstall-linux.sh"

no_proxy_value="localhost,127.0.0.1,::1"
if [[ -n "$no_proxy_extra" ]]; then
    no_proxy_value="$no_proxy_value,$no_proxy_extra"
fi

config_temp="$(mktemp "$config_dir/config.sh.new.XXXXXX")"
{
    printf '%s\n' '# Generated by clash-ssh-proxy-bootstrap. Do not commit this file.'
    printf "CLASH_SSH_PROXY='http://127.0.0.1:%s'\n" "$remote_proxy_port"
    printf "CLASH_SSH_NO_PROXY='%s'\n" "$no_proxy_value"
} > "$config_temp"
chmod 600 "$config_temp"
mv -f -- "$config_temp" "$config_dir/config.sh"

update_startup_file "$HOME/.bashrc"
if [[ "$login_file" != "$HOME/.bashrc" ]]; then
    update_startup_file "$login_file"
fi

bash -n "$config_dir/proxy-on.sh"
bash -n "$config_dir/proxy-off.sh"
bash -n "$config_dir/shell-init.sh"
bash -n "$config_dir/check-linux.sh"
bash -n "$config_dir/uninstall-linux.sh"

printf 'Installed account proxy for %s on 127.0.0.1:%s\n' "$USER" "$remote_proxy_port"
printf 'Open a new shell or run: source ~/.bashrc\n'
