# Changelog

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
