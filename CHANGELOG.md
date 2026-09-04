# Changelog

## Unreleased

- Launch SSH public-key setup through an explicitly interactive console, keep
  failures visible until acknowledged, force interactive SSH batch mode off,
  and explain that typed or pasted passwords do not echo. Document right-click
  and Shift+Insert as paste fallbacks when Ctrl+V is unavailable.
- Add frontend tests and a CI build that verifies the committed `web/dist`
  bundle stays synchronized with TypeScript source, with ESLint and React Hooks
  checks in the same required frontend command.
- Isolate React smoke tests from the production single-instance mutex, deliver
  the local session token through a redacted URL fragment, and harden the local
  HTTP bridge with origin checks, request-size limits, and browser security headers.
- Recreate the local HTTP listener when probing a fallback port so opening a
  second isolated instance no longer reuses a listener invalidated by a bind conflict.
- Move manager-state normalization and target-form conversion out of the main
  React component, isolate bridge synchronization in a dedicated hook, and
  cover the extracted pure behavior with unit tests.
- Replace source-shape assertions for tunnel fast paths, status probes,
  enable/disable transactions, reconciliation, and Linux health fallback with
  behavior-oriented tests.
- Add a documented contributor check and a tag-driven release workflow that
  validates versions, repeats cross-platform tests, and publishes a Git archive
  with a SHA-256 checksum.

- Delay logon tunnel startup until the Windows network has time to initialize,
  supervise SSH with five-second retries inside the windowless launcher, and
  keep the Task Scheduler fallback restart count within its XML schema range.
- Reconcile enabled targets whose tasks are unexpectedly `Ready` or `Disabled`
  when the manager opens. One hidden process waits up to 30 seconds for Clash,
  then locks and recovers targets sequentially so the UI remains responsive and
  manual actions do not compete with per-target workers. Missing tasks now direct
  the user to Edit / Update instead of attempting an invalid start.
- Remove the unused launcher sidecar status file and custom UI recovery error
  protocol, detach instead of force-killing an active reconciliation, align the
  local startup wait with the five-second supervisor retry, and behavior-test the
  simplified recovery handoff.
- Opt supported Node.js processes into the account-wide Linux proxy through
  `NODE_USE_ENV_PROXY`, and remove the opt-in together with `proxy_off`.

## 1.0.0 - 2026-08-13

- Publish the first stable release of the multi-target Windows desktop manager,
  PowerShell CLI, and account-wide Linux proxy integration.
- Include windowless logon tasks, one-click access control, parallel health and
  closure checks, and automatic SSH public-key setup for new Linux targets.
- Harden task ownership, exact SSH process matching, configuration validation,
  rollback behavior, privacy checks, and symlink-safe Linux installation.
- Keep draining exact managed SSH tunnel processes during task shutdown until
  they remain absent for a short quiet period, preventing a Disable race from
  reporting failure after the task was already disabled.
- Run the full UI smoke suite once and use a lightweight windowless-launcher
  probe for the VBS handoff, removing a duplicate process-tree race from CI.

## 0.2.9 - 2026-08-12

- Migrate renamed scheduled tasks without leaving the old logon trigger behind,
  refuse unrelated task-name collisions, and fail closed after registration,
  verification, or configuration-save failures.
- Match managed SSH processes by the complete executable and argument signature,
  including identity and SSH port, instead of broad destination substrings.
- Read BOM-less configuration explicitly as strict UTF-8 on Windows PowerShell
  5.1 and PowerShell 7, and align runtime validation with the JSON Schema.
- Preserve Bash startup-file symbolic links during Linux install and uninstall;
  preflight malformed managed blocks and reject dangling or non-file targets.
- Add Windows PowerShell 5.1, PowerShell 7, Linux, and repository-privacy CI,
  with failure-injection and symlink regression coverage.
- Prepare a passwordless Ed25519 identity automatically when the selected key
  is missing, and rebuild a stale or missing public-key file from the private key.
- Preflight SSH public-key authentication before opening an interactive console;
  already-authorized targets no longer show a password window.
- Enable automatic SSH login setup by default when a target is added in the
  desktop manager, while never passing or storing the Linux password.
- Move SSH identity/bootstrap responsibilities into a dedicated manager module
  and add Windows PowerShell 5.1 integration and UI routing coverage.
- Bound hidden `ssh-keygen` processes and close their standard input so an
  unexpected prompt cannot leave the desktop manager waiting indefinitely.
- Generate new identities through verified same-directory temporary files so a
  concurrent key cannot be overwritten or removed during failure cleanup.
- Preserve an existing final `authorized_keys` line that lacks a trailing
  newline before appending the managed public key.
- Detect an existing authorized key by key type and material even when its line
  has options or a comment, preserving restrictions instead of adding an
  unrestricted duplicate; disabled comment lines remain disabled.
- Reject target host or user values beginning with `-`, preventing OpenSSH from
  interpreting a destination as an injected command-line option.
- Replace repaired public-key files through a same-directory temporary file,
  avoiding writes through a hard link or reparse-point destination.
- Bound the one-time interactive SSH connection attempt to the same eight-second
  connection timeout used by non-interactive probes.

## 0.2.8 - 2026-08-12

- Run manual Health check per target in parallel hidden processes without
  disabling the rest of the desktop UI; click the same button to cancel.
- Cancel and terminate an older target-scoped check before a newer health or
  access operation starts, preventing stale PowerShell/SSH work from lingering.
- Combine enabled-target SSH reachability and proxy verification into one SSH
  session while preserving distinct SSH and proxy status values.
- Enforce one desktop-manager instance per Windows session.
- Serialize each complete config read/modify/write transaction across processes
  with a path-scoped named mutex and clean temporary files after failed saves.
- Record per-target check duration and completion time in JSON status output and
  show elapsed time in the desktop log.
- Split the CLI and desktop implementation into shared, manager, and UI modules
  while keeping the public entry scripts and commands compatible.

## 0.2.7 - 2026-08-12

- Return from Disable after the scheduled task is disabled and managed SSH
  processes are closed locally; verify the remote port in a hidden background
  status check.
- Stop scheduled tasks through the Task Scheduler COM service and use bounded,
  PID-scoped process waits to avoid repeated slow module and CIM queries.
- Add `Open-ProxyManager.vbs` as the truly windowless desktop entry point and
  keep `Open-ProxyManager.cmd` as an immediate compatibility shim.
- Keep the elevated UI PowerShell host hidden. Open a separate visible console
  only for explicit, interactive SSH public-key installation.

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
