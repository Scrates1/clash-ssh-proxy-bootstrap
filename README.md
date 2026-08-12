# clash-ssh-proxy-bootstrap

Use one Windows machine running Clash to provide an account-wide proxy for one
or more remote Linux hosts through loopback-only SSH reverse tunnels.

The project is designed for this topology:

```text
Linux host A ─┐
Linux host B ─┼─ SSH reverse tunnels ─> Windows 127.0.0.1:7897 ─> Clash ─> Internet
Linux host C ─┘
```

Each Linux host gets its own persistent SSH connection and Windows scheduled
task. Different Linux hosts may all use remote port `17897` because each port
lives on a different machine.

A Windows desktop manager and the PowerShell CLI use the same private
configuration and the same task-management commands.

## Security model

- The Linux proxy endpoint is fixed to `127.0.0.1`; it is never exposed on
  `0.0.0.0`.
- Passwords are never accepted as command-line parameters or written to disk.
- Scheduled tunnels require SSH public-key authentication.
- Scheduled tasks use `StrictHostKeyChecking=yes`.
- The Windows `targets` list controls per-target access. Disabling a target stops
  and disables only that target's tunnel task.
- Loopback binding prevents other network machines from using a target's
  endpoint. Other local accounts on an enabled Linux host could still connect
  to the loopback port if they know it; shell integration is installed only for
  the selected account.
- Machine-specific host names, user names, ports, and key paths are stored by
- Windowless scheduled-task launchers are stored under
  `%ProgramData%\ClashSshProxy\tasks` with write access restricted to
  Administrators and SYSTEM.
  default in `%LOCALAPPDATA%\ClashSshProxy\config.json`, outside this Git repo.
- SSH private keys, application tokens, Codex `auth.json`, and remote shell
  backups must not be committed.

## Requirements

Windows controller:

- Windows 10 or 11
- PowerShell 5.1 or newer
- Windows OpenSSH Client (`ssh.exe`, `scp.exe`)
- Clash or another HTTP-compatible mixed proxy listening on loopback
- Administrator PowerShell for scheduled-task changes

Linux target:

- Bash
- OpenSSH server
- `curl`, plus standard GNU userland tools
- A reachable SSH account; root is not required

## Windows desktop manager

Double-click:

```text
Open-ProxyManager.cmd
```

Accept the Windows administrator prompt once. The desktop manager provides:

- target add, edit, update, and removal;
- one state-aware **Enable proxy / Disable proxy** access control, also available
  by clicking the target's **Enabled** checkbox directly;
- scheduled-task state and local Clash availability;
- end-to-end SSH and remote proxy health checks;
- SSH private-key selection and optional public-key bootstrap.
- UTF-8 log rendering for Windows PowerShell and native SSH output.

**Disable proxy** closes access to this Windows Clash tunnel. It is not a Linux firewall and does not prevent the target from using a separate direct Internet route.

See the [Chinese Windows UI guide](docs/WINDOWS-UI.zh-CN.md) or click **Help** in the manager for button behavior, status meanings, and troubleshooting.

Quick refresh reads only local state. **Health check** contacts every Linux
target and can take several seconds per unreachable host. If public-key
bootstrap needs a Linux password, enter it in the PowerShell console; the UI
does not receive or store it.

Scheduled tunnels run through a windowless WScript launcher. After the target is
updated to version 0.2.4 or newer, clicking **Enable proxy** does not create or
flash a separate SSH console window.

## Quick start

Open an elevated PowerShell window in this repository.

If the Linux host does not yet accept the Windows public key, bootstrap it once:

```powershell
.\proxy-manager.ps1 bootstrap-key `
  -Name development-server `
  -RemoteHost linux.example.com `
  -RemoteUser linuxuser
```

SSH may ask for the Linux password once. The script transfers only the public
key and never stores the password.

Add and install the target:

```powershell
.\proxy-manager.ps1 add `
  -Name development-server `
  -RemoteHost linux.example.com `
  -RemoteUser linuxuser `
  -LocalProxyPort 7897 `
  -RemoteProxyPort 17897
```

The single Windows command uploads and installs the Linux-side files, creates
the scheduled tunnel task, starts it, and verifies the proxy.

Check every managed target:

```powershell
.\proxy-manager.ps1 status
```

## Existing installations

Use `adopt` when a Linux host and scheduled task already work and should be
recorded without reinstalling them:

```powershell
.\proxy-manager.ps1 adopt `
  -Name existing-server `
  -RemoteHost linux.example.com `
  -RemoteUser linuxuser `
  -TaskName ClashProxyToExistingServer
```

After adoption, run `update` once to migrate it to the repository-managed file
layout:

```powershell
.\proxy-manager.ps1 update -Name existing-server
```

## Multiple Linux hosts

Run `add` once per host. Each target receives an independent scheduled task:

```powershell
.\proxy-manager.ps1 add -Name server-a -RemoteHost server-a.example.com -RemoteUser alice
.\proxy-manager.ps1 add -Name server-b -RemoteHost server-b.example.com -RemoteUser bob
.\proxy-manager.ps1 status
```

Updating one host does not stop the others:

```powershell
.\proxy-manager.ps1 update -Name server-b
```

Update all recorded hosts:

```powershell
.\proxy-manager.ps1 update-all
```

Disable one Linux host without removing its configuration:

```powershell
.\proxy-manager.ps1 disable -Name server-b
```

When the Linux host is reachable, `disable` also verifies that its loopback
proxy port is closed. A health check reports `BLOCKED` when confirmed,
`LEAK` if the port is still open, and `UNKNOWN` when SSH is unavailable.

Enable it again and verify its proxy:

```powershell
.\proxy-manager.ps1 enable -Name server-b
```

`enable` and `disable` are the only public tunnel state controls. Internal
task-start and task-stop routines remain implementation details and are not
exposed as separate commands. The desktop manager does not repeat a full health
check after these commands because the commands already verify their result. Use
**Health check** whenever you want a fresh end-to-end status for every target.

## Configuration

The manager's default private state file is:

```text
%LOCALAPPDATA%\ClashSshProxy\config.json
```

Use `-Config PATH` to select another file. `config.example.json` documents the
format. Target-level values override defaults.

```json
{
  "version": 1,
  "proxy": {
    "localHost": "127.0.0.1",
    "localPort": 7897
  },
  "defaults": {
    "sshPort": 22,
    "identityFile": "~/.ssh/id_ed25519",
    "remoteProxyPort": 17897,
    "noProxyExtra": []
  },
  "targets": []
}
```

The following values may be overridden for each target:

- `enabled` (optional; defaults to `true` for older configurations)
- `sshPort`
- `identityFile`
- `remoteProxyPort`
- `noProxyExtra`
- `taskName`

The remote bind address is deliberately not configurable.

## Commands

| Command | Purpose |
|---|---|
| `bootstrap-key` | Interactively append the Windows public key to one Linux account |
| `add` | Install and start a new target, then save it in the manager config |
| `adopt` | Record an already-working target without changing it |
| `status` | Check scheduled tasks, SSH, and remote proxy health |
| `enable` | Enable and start one target persistently |
| `disable` | Disable and stop one target persistently |
| `update` | Reinstall one target idempotently and refresh its task |
| `update-all` | Update every recorded target |
| `remove` | Remove one task and its Linux shell integration |
| `validate-config` | Validate JSON structure and parameter ranges |

Run `.\proxy-manager.ps1 help` for a compact command reference.

## Linux installation layout

The generated runtime configuration is intentionally separate from the source
checkout:

```text
~/.config/clash-ssh-proxy/
├── README.md
├── config.sh
├── proxy-on.sh
├── proxy-off.sh
├── shell-init.sh
├── check-linux.sh
├── uninstall-linux.sh
└── backups/
```

The installer adds one managed block near the beginning of the active Bash
startup files. Re-running it replaces the same block instead of appending
duplicates.

On Linux:

```bash
proxy_status
proxy_off
proxy_on
```

The proxy is enabled for new Bash login sessions and programs launched from
them. `sudo`, systemd services, cron, Docker containers, and other users may not
inherit this environment and require separate configuration.

## Failure behavior

The scheduled task restarts a failed SSH tunnel every minute. A Linux host
loses proxy access when Windows is off or logged out, Clash is stopped, the
network is unavailable, or its SSH task cannot connect. Other configured Linux
hosts continue independently.

A disabled target remains disabled across Windows logons. Its Linux proxy files
remain installed so enabling it again does not require reinstalling the host.

Use `proxy_off` in an affected Linux shell when temporary direct access is
preferred.

## Development and tests

Linux tests:

```bash
bash tests/test-linux.sh
```

PowerShell parser and configuration tests:

```powershell
.\tests\Test-Manager.ps1
```

The PowerShell suite includes parser, legacy-config migration, JSON status, and
headless Windows UI smoke tests.

The Linux installer test uses a temporary HOME, runs installation twice to
verify idempotency, and verifies that uninstall preserves unrelated shell
settings.
