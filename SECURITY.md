# Security

Do not open an issue containing passwords, access tokens, private keys, full
`authorized_keys` files, Codex `auth.json`, or a real per-machine config.

The repository intentionally keeps machine-specific values outside Git. The
default Windows state file is `%LOCALAPPDATA%\ClashSshProxy\config.json`.

The Linux reverse-forward endpoint must remain bound to `127.0.0.1`. The
manager does not expose a parameter for changing that bind address.

The Windows management bridge also listens only on `127.0.0.1`. Each process
creates a random bearer token, places it in a URL fragment that is not sent in
the initial HTTP request, and removes it from the visible URL after the React
client reads it. API calls require the token in a custom header and reject a
foreign browser origin. Responses apply a restrictive content security policy,
and request bodies are bounded. These controls protect against unrelated web
pages; they are not an isolation boundary against another process already
running as the same Windows user.

The Windows target list controls access per Linux machine. It does not provide
per-process or per-user authorization within an allowed Linux machine. Only the
selected Linux account receives automatic shell integration, but another local
account could manually connect to a known loopback proxy port. Use host-level
firewall or account isolation when that distinction is required.
