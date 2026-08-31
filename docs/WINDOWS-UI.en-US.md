# Windows Manager UI Guide

Current stable version: 1.0.0.

For the Chinese version, see [Windows 管理界面使用说明](WINDOWS-UI.zh-CN.md).

## Opening the manager

Double-click `Open-ProxyManager.vbs` in the repository root to open the manager
without a black console window. Choose **Yes** when Windows shows the elevation
prompt. Administrator permission is required to manage scheduled tasks.

`Open-ProxyManager.cmd` remains available for compatibility. It immediately
hands off to the VBS launcher and exits, although Windows may briefly flash a
CMD window while starting a `.cmd` file. The UAC prompt is an expected security
confirmation and cannot be hidden. Starting with 0.2.9, adding a target prepares
its SSH key automatically and performs a silent preflight check. A separate
PowerShell window appears only when Linux has not accepted the public key yet,
so that the one-time Linux password can be entered. The password is never sent
to the UI or stored.

The default entry point uses the React/Vite dashboard. The page is displayed in
a local Edge app window, and the PowerShell bridge listens only on `127.0.0.1`;
the manager API is not exposed to the LAN. If the React bundle is missing, run
`npm install` and `npm run build` in the repository's `web` directory. You can also use
`Open-ProxyManager-React.cmd` to start the React entry point explicitly.
The React dashboard supports English and Chinese. Click `EN / 中` in the upper
right corner to switch languages. The choice is saved in the local browser and
is reused the next time the dashboard opens. Without a saved choice, the
dashboard follows a Chinese browser locale and otherwise defaults to English.

The sidebar's **Overview**, **Targets**, and **Activity** entries are separate
pages. Overview shows the operating summary, Targets manages the target list and
details, and Activity shows the complete operation log. Switching pages does
not use an automatic dropdown or scroll jump.

Starting with 0.2.4, scheduled tunnel tasks use a truly windowless launcher, so
clicking **Enable proxy** does not create or flash an SSH console window.
Starting with 0.2.8, only one manager window is allowed per Windows session;
launching another instance reports the existing instance instead of allowing
two windows to edit the same configuration.

Launchers are stored under `%ProgramData%\ClashSshProxy\tasks` and are readable
only by Administrators and SYSTEM, preventing ordinary processes from altering
the elevated scheduled tasks.

## Top-level and table states

- `Local proxy [UP]`: the Clash port is listening on Windows.
- `Local proxy [DOWN]`: Clash is stopped, or the configured local port is wrong.
- `Enabled`: this Linux target is persistently enabled; click the checkbox to
  toggle it directly.
- `Task`: Windows scheduled-task state, commonly `Running`, `Ready`, or
  `Disabled`.
- `SSH`: whether Windows can reach Linux through SSH public-key authentication.
- `Proxy`: the end-to-end proxy state.
  - `OK`: the proxy is usable.
  - `CHECKING`: the UI is verifying proxy access after enabling, or verifying
    that the remote port closed after disabling.
  - `RECOVERING`: one hidden coordinator is sequentially repairing scheduled
    tasks that need recovery; other controls remain available.
  - `FAIL`: the target is enabled, but the proxy check failed.
  - `DISABLED`: a quick refresh confirmed that the target is configured as
    disabled; no remote check has been performed yet.
  - `BLOCKED`: a deep check confirmed that the remote proxy port is closed.
  - `LEAK`: the target is disabled, but its remote proxy port is still open;
    investigate other tunnels immediately.
  - `UNKNOWN`: Linux is offline or SSH is unavailable, so the remote state could
    not be confirmed.

Gray rows are persistently disabled. Pale red rows indicate an enabled target
whose task is not running. Red rows indicate `LEAK`.

When the manager opens, it identifies enabled targets whose tasks are unexpectedly
`Ready` or `Disabled`, then starts one hidden coordinator. The coordinator waits
up to 30 seconds for Clash and recovers targets in configuration order. The UI
then performs end-to-end verification, so recovery does not lock the window or
start one recovery process per machine. A `Missing` task is not started blindly;
the UI shows `Update required`, and **Edit / Update** must recreate it. Logon
tasks have a fixed 15-second delay, and a windowless launcher retries an exited
SSH tunnel every five seconds so that a machine starting before the network is
ready does not remain permanently stopped.

## Button reference

### Add target

Adds and installs a Linux target. The manager uploads the Linux files, creates an
independent scheduled task, starts the tunnel, and verifies the proxy. Each new
target receives its own target ID and a dedicated passwordless Ed25519 key under
the Windows manager directory. If the public-key preflight succeeds, no console
appears. Otherwise, a console opens for one password entry; the password is
never stored.

### Edit / Update

Changes target parameters and redeploys the Linux files and Windows scheduled
task. The target may briefly disconnect during the update; other targets are not
affected. When the task name changes, the old task is stopped and unregistered
first. If the new name is already used by another task, the update is rejected
without overwriting it. If startup, verification, or configuration saving
fails, the replacement tunnel is stopped and unregistered. Run **Update** again
to rebuild it; this does not leave an unrecorded logon task behind.

### Enable proxy / Restart proxy / Disable proxy

The dynamic primary button and the `Enabled` checkbox perform the same action.
They can be clicked directly without a confirmation dialog. Normal successful
operations do not show a success popup; only a synchronous startup failure is
shown as an error:

- When disabled, the button is **Enable proxy**. It persistently allows the
  selected Linux target to use this Windows proxy and starts its tunnel. The
  local Clash listener, scheduled task, and managed SSH process are checked
  before the command returns. The row then shows `CHECKING`; a hidden process
  verifies only that target and changes the result to `OK` or `FAIL`. Other
  targets and controls remain usable. The task starts automatically at the next
  Windows logon.
- When enabled but the task is `Ready` or `Disabled`, the button is **Restart
  proxy**. It keeps the access decision unchanged, recovers the tunnel in the
  background, and verifies the proxy.
- When the task is `Missing`, the button is **Update required** and does not try
  to start anything. Use **Edit / Update** to recreate the task.
- When enabled, the button is **Disable proxy**. It persistently prevents the
  selected Linux target from using this Windows Clash proxy. It:

  1. stops and disables the target's scheduled task;
  2. removes matching managed SSH reverse-tunnel processes;
  3. saves the disabled state and returns control to the UI;
  4. asks a hidden background process to confirm that the remote proxy port is
     closed.

The synchronous phase waits only for the local task and managed SSH processes
to close, so Linux network latency does not block the operation. The row then
shows `CHECKING` and eventually becomes `BLOCKED`, `LEAK`, or `UNKNOWN`.
`BLOCKED` means the remote port was confirmed closed; `LEAK` is shown in red.
Click **Health check** when all targets need a fresh SSH/proxy status.

**Disable proxy** is not a Linux firewall. If Linux has another direct Internet
route, it can still connect directly. It also does not uninstall the Linux files.
Existing Linux shells may retain variables such as `HTTP_PROXY`, but their proxy
port is no longer available, so network commands may fail. Run `proxy_off` in
the current Linux shell when temporary direct access is needed.

### Advanced SSH settings

Infrequent maintenance operations are grouped here:

- When adding or editing a target, the normal form does not require selecting a
  private key. Expand **Advanced SSH settings** to specify an external key
  path. Leave it empty to use the dedicated Ed25519 key associated with the
  target ID. Different targets cannot share one private-key path.
- **Configure SSH login** prepares the target's dedicated or specified Windows
  key and checks whether the selected Linux account accepts its public key. If
  passwordless login already works, no console opens. Otherwise, one PowerShell
  console opens for the Linux password. The private key and password are never
  copied or stored by the manager.
- **Refresh local status** reads only the Windows configuration, Clash port, and
  scheduled-task state. It does not connect to Linux and is fast.
- **Remove target** first shows a confirmation dialog. After confirmation, the
  Windows scheduled task, Linux proxy shell integration, and matching
  `authorized_keys` public key are removed. For a manager-generated dedicated
  key, the dialog is checked by default to remove the local private key and
  `.pub` file as well. A manually specified external key is never removed
  automatically. The Linux account itself is not deleted. If remote cleanup
  fails, the target configuration is retained so the operation can be retried.

### Health check

Connects to every Linux target and checks SSH, proxy availability, or the
disabled state. An unreachable host may take several seconds. This is the full
manual end-to-end check; `BLOCKED` means the disabled state was confirmed on the
remote host. Starting with 0.2.8, each target is checked by its own hidden
process in parallel. The table shows `CHECKING` per row while other controls
remain usable. The button becomes **Cancel checks**; click it again to cancel
all manual checks and terminate their PowerShell/SSH processes.

Starting a new Health check, Enable, or Disable operation for the same target
cancels its older check. This prevents stale results or processes from
remaining active. The log records the duration of each target check.

## Frequently asked questions

### Why is there no Start / Stop button?

Those actions create confusing intermediate states such as “enabled but not
running”. Since 0.2.3, the UI and public CLI expose only **Enable** and
**Disable**; internal task start/stop routines remain implementation details.

### Why does Open-ProxyManager.cmd show a window?

A `.cmd` file must be run by the Windows CMD host, so an absolutely flash-free
start cannot be guaranteed. Since 0.2.7 it only hands off quickly and does not
keep a PowerShell window open. Double-click `Open-ProxyManager.vbs` when no
black window is desired. The UAC prompt is expected. A separate interactive
console appears only when the SSH preflight confirms that the Linux public key
is not installed, or when **Configure SSH login** actually needs to install it.

### Why were Enable / Disable slow before?

Older versions repeated a full Health check after the command had already
verified its result. Version 0.2.4 removed the duplicate check and combined the
SSH and port probes used for disabling. Version 0.2.6 moved Enable's end-to-end
proxy check to a hidden background process; 0.2.7 did the same for Disable's
remote-port confirmation. The button now waits only for local task and managed
SSH process changes. Since 0.2.8, manual Health check runs targets in parallel
without locking the UI, and enabled-target SSH reachability and proxy access
share one SSH session.

### Why did a target row briefly disappear after enabling?

Older refresh logic cleared the whole table before adding rows again. Since
0.2.6, existing rows are updated in place and the grid uses double buffering.
The target row, checkbox, and current selection no longer disappear during
Enable.

### Why can Linux commands not connect after Disable proxy?

The Linux shell may still try to use the closed proxy port. Run `proxy_off` in
the current shell to use a direct route temporarily. After **Enable proxy**, new
and existing shells can use the proxy again.

### Why does Proxy show FAIL?

Confirm that Windows Clash is running and the top bar shows `[UP]`, then click
**Enable proxy** and run **Health check**. Also confirm that Windows can log in
to the Linux target through SSH public-key authentication. The log's `Reason`
distinguishes `task-stopped`, `task-disabled`, `task-missing`,
`ssh-unreachable`, and `remote-proxy-unavailable`, so it can guide the first
diagnostic step instead of relying only on `FAIL`.

Since 0.2.5, health checks try Gstatic, Cloudflare, and Google in sequence. A
single site failure no longer marks the whole proxy as failed. `OK` means the
proxy route works; it does not guarantee access to every website. If only
Google or another specific site fails, inspect the current Clash node and rules.

### Why does Proxy show LEAK?

The disabled configuration does not match the remote port state. Check for
another manually created reverse tunnel or another Windows controller. Enable
the target and then click **Disable proxy** again to clean up managed tunnels on
this computer.

### Why do logs contain garbled text or ANSI color codes?

Reopen it through `Open-ProxyManager.vbs`. Since 0.2.2,
the launcher, Windows PowerShell, and SSH/SCP output use UTF-8, and the log box
removes ANSI color-control sequences. Since 0.2.9, configuration files are
also read explicitly as UTF-8 under Windows PowerShell 5.1, so Chinese task
names no longer depend on the system ANSI code page.

### What happens if multiple windows or commands run at once?

The manager enforces one UI instance per Windows session. CLI and UI mutations
also hold a configuration-path mutex across the complete read, task/remote
operation, and save transaction. A second mutation waits for the first one and
reports a clear timeout instead of overwriting newer configuration with stale
data. Local refresh and status-only checks do not hold the write lock.

## Control boundary

The tool authorizes a Linux host as a whole, not individual websites, URLs, or
Linux processes. The remote proxy port listens only on Linux `127.0.0.1` and is
not exposed to other LAN machines. However, another local account on the same
Linux host that knows the port may still connect to it. Strict multi-account
isolation requires additional Linux firewall or account-isolation policy. The
tool also does not prevent Linux from using its own direct Internet route.
