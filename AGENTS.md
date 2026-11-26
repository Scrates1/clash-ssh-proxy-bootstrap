# AI Agent Guide for clash-ssh-proxy-bootstrap

This repository manages Windows-to-Linux Clash SSH reverse proxy tunnels. All state mutations, SSH keys, and Windows Scheduled Tasks are governed by a **single core engine** (`proxy-manager.ps1` + `src/manager/*`).

## Hard Rules (MUST Follow)

1. **Never edit `%LOCALAPPDATA%\ClashSshProxy\config.json` directly.**
2. **Never manually create or edit `ClashProxyTo*` Windows Scheduled Tasks or `C:\ProgramData\ClashSshProxy\tasks\*.vbs`.**
3. **Never assign the same SSH private key to multiple targets.** Every target must have its own dedicated managed key under `%LOCALAPPDATA%\ClashSshProxy\keys\tgt-<id>.ed25519` (generated automatically when `-IdentityFile` is omitted).
4. **Always use `proxy-manager.ps1` as the single source of truth**, preferring `-Json` for machine-readable output.
5. **Respect Windows UAC / Administrator boundaries**:
   - **Read-only / non-elevated safe**: `doctor -Json`, `status -Json`, `validate-config -Json`, `prepare-ssh -Json`, `bootstrap-key`.
   - **Elevated Administrator required**: `add`, `update`, `enable`, `disable`, `remove`, `reconcile`.
   - Always check `isElevated` from `.\proxy-manager.ps1 doctor -Json` before running mutating commands. If `isElevated` is `false`, do **not** bypass the manager or weaken scheduled-task ACLs—present the exact `proxy-manager.ps1` command for the user to run in an elevated PowerShell window (or instruct them to use `Open-ProxyManager.vbs`).
6. **Require explicit user approval before deploying keys**:
   - Before using `-BootstrapIdentityFile` to upload a newly generated dedicated public key via an existing local private key, confirm with the user first.
   - Never persist `-BootstrapIdentityFile` into `config.json`.
7. **Verify after every change**:
   - Run `.\proxy-manager.ps1 validate-config -Json` and `.\proxy-manager.ps1 doctor -Json` (or `status -Json`) and confirm all targets report healthy (`SSH=OK`, `Proxy=OK`).

## Standard AI Workflow for Adding a Linux Target

```powershell
# 1. Inspect current environment and elevation status
.\proxy-manager.ps1 doctor -Json

# 2. Generate a dedicated TargetId + managed Ed25519 key and probe SSH readiness
$prep = .\proxy-manager.ps1 prepare-ssh -Name edge-prod -RemoteHost 203.0.113.10 -RemoteUser ubuntu -RemoteProxyPort 17897 -Json | ConvertFrom-Json

# 3. If not ready ($prep.InteractionRequired -eq $true):
#    Option A (with user consent & existing authorized key):
.\proxy-manager.ps1 bootstrap-key -Name edge-prod -TargetId $prep.TargetId -RemoteHost 203.0.113.10 -RemoteUser ubuntu -BootstrapIdentityFile ~/.ssh/id_ed25519 -Json
#    Option B (interactive password setup): ask the user to run bootstrap-key or use Open-ProxyManager.vbs.

# 4. Install Linux integration + Windows scheduled task (requires elevated PowerShell)
.\proxy-manager.ps1 add -Name edge-prod -TargetId $prep.TargetId -RemoteHost 203.0.113.10 -RemoteUser ubuntu -RemoteProxyPort 17897 -Confirm:$false -Json

# 5. Mandatory post-change verification
.\proxy-manager.ps1 validate-config -Json
.\proxy-manager.ps1 status -Json
```

## Development & CI Guardrails (When Editing This Repository)

- Keep `proxy-manager.ps1` under **300 lines** and `proxy-manager-react-host.ps1` under **500 lines** (enforced by `tests/Test-Manager.ps1`).
- Maintain compatibility with both **Windows PowerShell 5.1** and **PowerShell 7**.
- Keep `web/dist` synchronized with `web/src` (`cd web && npm run check`).
- Never commit private RFC 1918 IPv4 addresses, personal usernames, or key material (enforced by `tests/test-privacy.sh`). Use RFC 5737 documentation IPs (`203.0.113.10`, `198.51.100.8`, `192.0.2.17`).
