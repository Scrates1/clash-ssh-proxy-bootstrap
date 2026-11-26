---
name: clash-ssh-proxy
description: Safely manage Windows-to-Linux Clash SSH reverse proxy tunnels through proxy-manager.ps1 with per-target managed Ed25519 keys, structured JSON diagnostics, and UAC-aware workflows.
---

# Clash SSH Proxy Manager Skill

Use this skill whenever the user asks to inspect, diagnose, add, update, enable, disable, or remove a Clash SSH reverse proxy tunnel on Windows managed by `clash-ssh-proxy-bootstrap`.

## Non-Negotiable Safety Rules

1. **Single Entry Point**: Perform all diagnostics and mutations through `proxy-manager.ps1`. Never hand-edit `%LOCALAPPDATA%\ClashSshProxy\config.json`, never hand-edit `C:\ProgramData\ClashSshProxy\tasks\*.vbs`, and never manually register `ClashProxyTo*` tasks.
2. **One Dedicated Managed Key Per Target**: Omit `-IdentityFile` when onboarding targets so `proxy-manager.ps1` automatically creates and manages `%LOCALAPPDATA%\ClashSshProxy\keys\tgt-<id>.ed25519`. Never reuse one private key across two targets.
3. **Explicit Consent for Key Deployment**: Ask for user confirmation before running `bootstrap-key -BootstrapIdentityFile <existing-key>` to install a newly generated dedicated public key onto a remote Linux host.
4. **UAC Elevation Honesty**:
   - Check `isElevated` via `.\proxy-manager.ps1 doctor -Json` first.
   - Read-only commands (`doctor`, `status`, `validate-config`) work without elevation.
   - Mutating commands (`add`, `update`, `enable`, `disable`, `remove`, `reconcile`) require an **elevated Administrator PowerShell**. If `isElevated` is `false`, do not attempt workarounds—give the user the exact command to run in an elevated shell or direct them to `Open-ProxyManager.vbs`.
5. **Post-Change Verification**: After any mutation, always run `.\proxy-manager.ps1 validate-config -Json` and `.\proxy-manager.ps1 status -Json` to verify healthy end-to-end status.

## Commands Reference

### 1. Full Health & Privilege Diagnostics (Start Here)
```powershell
.\proxy-manager.ps1 doctor -Json
```
Inspect:
- `data.isElevated`: whether mutating commands can run in this shell.
- `data.config.valid` / `data.config.errorCode`: catches syntax errors or `DUPLICATE_IDENTITY`.
- `data.localProxy.up`: verifies local Clash is listening (`127.0.0.1:7897`).
- `data.targets`: per-target `taskState`, `taskOwned`, `ssh`, `proxy`, `identityManaged`.
- `data.orphanKeys`: unused managed key files under `keys/` (informational; do not delete without user confirmation).

### 2. Onboarding a New Target (Zero Orphan Keys)
Always reuse `TargetId` returned by `prepare-ssh -Json` across `bootstrap-key` and `add`:

```powershell
# Step 1: Initialize dedicated managed key and test SSH readiness
$prep = .\proxy-manager.ps1 prepare-ssh -Name edge-prod -RemoteHost 203.0.113.10 -RemoteUser ubuntu -RemoteProxyPort 17897 -Json | ConvertFrom-Json

# Step 2 (if $prep.Ready is false):
# If the user already has passwordless SSH access and explicitly approves:
.\proxy-manager.ps1 bootstrap-key -Name edge-prod -TargetId $prep.TargetId -RemoteHost 203.0.113.10 -RemoteUser ubuntu -BootstrapIdentityFile ~/.ssh/id_ed25519 -Json
# Otherwise instruct the user to run bootstrap-key interactively (for password entry) or use Open-ProxyManager.vbs.

# Step 3 (requires elevated shell): Install Linux integration, register task, verify proxy
.\proxy-manager.ps1 add -Name edge-prod -TargetId $prep.TargetId -RemoteHost 203.0.113.10 -RemoteUser ubuntu -RemoteProxyPort 17897 -Confirm:$false -Json

# Step 4: Verify
.\proxy-manager.ps1 validate-config -Json
.\proxy-manager.ps1 status -Json
```

### 3. Enable / Disable / Remove
```powershell
.\proxy-manager.ps1 enable  -Name edge-prod -Confirm:$false -Json
.\proxy-manager.ps1 disable -Name edge-prod -Confirm:$false -Json
.\proxy-manager.ps1 remove  -Name edge-prod -DeleteIdentityFile -Confirm:$false -Json
```

## Common Error Codes & Recovery

| Error Code | Meaning | Action |
| :--- | :--- | :--- |
| `ELEVATION_REQUIRED` | Shell is not Administrator | Ask user to run the command in an elevated PowerShell or use `Open-ProxyManager.vbs`. |
| `DUPLICATE_IDENTITY` | Two targets share one private key | Generate a dedicated key for the conflicting target via `bootstrap-key` + `update`. |
| `HOST_KEY_NOT_TRUSTED` | Target host fingerprint is not in `known_hosts` | Ask user to verify the host fingerprint first or run interactive `bootstrap-key` once. |
| `BOOTSTRAP_AUTH_FAILED` | Existing bootstrap key was rejected | Verify the key is authorized on the host and loaded in `ssh-agent` if passphrase-protected. |
| `REMOTE_PROXY_PORT_ASSIGNED` / `REMOTE_PROXY_PORT_IN_USE` | Loopback port conflict on Linux host | Choose a different `-RemoteProxyPort` (e.g., `17898`). |
| `SSH_AUTH_REQUIRED` | Non-interactive `bootstrap-key -Json` called without `-BootstrapIdentityFile` | Obtain user consent for `-BootstrapIdentityFile` or use interactive `bootstrap-key`. |
