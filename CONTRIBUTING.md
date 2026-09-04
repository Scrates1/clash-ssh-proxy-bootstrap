# Contributing

## Required checks

Use Node.js 22 or later for the React UI. From `web/`, install the locked
dependencies and run the complete frontend check:

```powershell
npm ci
npm run check
```

`npm run check` runs ESLint, unit tests, TypeScript, and the production Vite
build. The application ships the committed `web/dist` directory so users do
not need Node.js. Commit the regenerated bundle whenever frontend source
changes; CI rejects source and bundle drift.

Run the Windows suite in both supported PowerShell hosts:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Manager.ps1
pwsh.exe -NoProfile -File .\tests\Test-Manager.ps1
```

Smoke tests use an isolated instance and fallback port, so the normal manager
may remain open. Tests must not use a real target configuration, change a real
scheduled task, or require a Linux password.

On Linux, run:

```bash
bash tests/test-linux.sh
bash tests/test-privacy.sh
```

Before committing, verify `git diff --check` and inspect every generated-file
change. Never commit machine-specific configuration, credentials, private
keys, `authorized_keys`, or copied production logs.

## Releases

A `v<version>` tag must match both `VERSION` and `web/package.json`. The release
workflow repeats all platform checks, verifies `web/dist`, and publishes a Git
archive with a SHA-256 checksum. Code signing is intentionally outside this
repository until a trusted signing identity is configured.
