# Security

Do not open an issue containing passwords, access tokens, private keys, full
`authorized_keys` files, Codex `auth.json`, or a real per-machine config.

The repository intentionally keeps machine-specific values outside Git. The
default Windows state file is `%LOCALAPPDATA%\ClashSshProxy\config.json`.

The Linux reverse-forward endpoint must remain bound to `127.0.0.1`. The
manager does not expose a parameter for changing that bind address.
