#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

sensitive_path_pattern='(^|/)(auth\.json|config\.json|credentials\.json|secrets\.json|authorized_keys|known_hosts(\.old)?|id_(rsa|dsa|ecdsa|ed25519)(\.pub)?|[^/]+\.(pem|key|ppk|p12|pfx))$'
tracked_files="$(git ls-files)"
if grep -Eq "$sensitive_path_pattern" <<< "$tracked_files"; then
    echo 'Tracked sensitive file path detected:' >&2
    grep -E "$sensitive_path_pattern" <<< "$tracked_files" >&2
    exit 1
fi

secret_pattern='BEGIN (OPENSSH|RSA|DSA|EC) PRIVATE KEY|sk-(proj-)?[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|password[[:space:]]*[:=][[:space:]]*["'"'][^"'"']+["'"']'
if matches="$(git grep -nEI "$secret_pattern" -- . ':(exclude)tests/test-privacy.sh' || true)" &&
    [[ -n "$matches" ]]; then
    printf '%s\n' "$matches"
    echo 'Possible committed credential detected' >&2
    exit 1
fi

private_ipv4_pattern='(^|[^0-9])(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3})([^0-9]|$)'
if matches="$(git grep -nE "$private_ipv4_pattern" -- . ':(exclude)tests/test-privacy.sh' || true)" &&
    [[ -n "$matches" ]]; then
    printf '%s\n' "$matches"
    echo 'Possible machine-specific private IPv4 address detected' >&2
    exit 1
fi

echo 'Privacy checks passed'
