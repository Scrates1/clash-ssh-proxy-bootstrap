# Changelog

## 0.2.6 - 2026-08-12

- Use the local Task Scheduler COM service for sub-second task lookup and start,
  avoiding multi-second PowerShell scheduled-task cmdlet initialization.
- Return from Enable after bounded local task and managed SSH process startup
  checks, while the desktop UI verifies the selected proxy end to end in a
  hidden background process.
- Add target-scoped JSON status checks so background verification does not wait
  for unrelated Linux hosts.
- Update existing grid rows in place and enable double buffering, preventing the
  selected target and checkbox from briefly disappearing during refresh.
- Display `CHECKING` while background verification is in progress and preserve
  explicit manual Health check behavior.

## 0.2.5 - 2026-08-12

- Verify proxy health against Gstatic, Cloudflare, and Google with fallback,
  preventing one blocked or unstable site from disabling an otherwise healthy
  SSH proxy tunnel.
- Keep each endpoint probe short so failed enable operations remain bounded.
- Make the Linux `proxy_status` helper use the same end-to-end health check as
  the Windows manager.

## 0.2.4 - 2026-08-12

- Make the Enabled checkbox directly toggle proxy access without confirmation or
  success dialogs; failures still display an error.
- Avoid the redundant full health check after enable and disable while keeping
  the backend end-to-end verification.
- Combine disabled-port and SSH reachability probes to reduce disable latency.
- Start scheduled tunnels through a WScript launcher with window style 0, avoiding
  the console flash caused by interactive powershell.exe startup.
- Store launchers in an Administrators/SYSTEM-only ProgramData directory to keep
  elevated scheduled-task execution tamper-resistant.

## 0.2.3 - 2026-08-12

- Replace separate Allow/Deny controls with one state-aware Enable/Disable button.
- Remove Start/Stop from the desktop UI and public CLI to eliminate conflicting states.
- Keep internal task start/stop functions solely as implementation details of enable,
  disable, update, and removal workflows.
- Move SSH-key installation, local refresh, and target removal into an Advanced menu.
- Preserve the selected target and update the primary action after every refresh.

## 0.2.2 - 2026-08-11

- Force UTF-8 for Windows PowerShell and native SSH/SCP output.
- Strip ANSI terminal control sequences before rendering UI log messages.
- Use a Chinese-capable font for the UI log pane.
- Rename Allow/Deny buttons to make their proxy-only scope explicit.
- Run an end-to-end health check automatically after Deny and show `BLOCKED`.
- Add native UTF-8 and ANSI-cleanup coverage to the UI smoke test.
- Prevent Windows PowerShell 5.1 from treating expected SSH probe stderr as a
  failed Deny operation.

## 0.2.1 - 2026-08-11

- Run scheduled SSH tunnels through a hidden PowerShell wrapper to prevent console popups.
- Stop matching residual SSH tunnel processes during stop, deny, update, and removal.
- Verify an online Linux target's reverse-tunnel port is closed after deny.
- Report denied targets as `BLOCKED`, `LEAK`, or `UNKNOWN` during health checks.
- Add button tooltips, a built-in Help dialog, and a detailed Chinese UI guide.
- Correct the repository version marker to match the released manager series.

## 0.2.0 - 2026-08-11

- Add a Windows desktop manager with per-target controls and health status.
- Add persistent `enable` and `disable` machine access controls.
- Add one-time `start` and `stop` tunnel controls.
- Add backward-compatible optional `enabled` target configuration.
- Add a machine-readable JSON status interface for the UI.
- Add legacy-config, JSON status, and headless UI tests.

## 0.1.0 - 2026-08-11

- Add one-command Windows orchestration for remote Linux installation.
- Support multiple independent Linux targets.
- Add SSH public-key bootstrap without password storage.
- Add idempotent Bash startup integration and safe uninstall.
- Add Windows scheduled-task management and end-to-end proxy checks.
