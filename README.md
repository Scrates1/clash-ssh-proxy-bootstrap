# clash-ssh-proxy-bootstrap

> 中文：使用一台运行 Clash 的 Windows 电脑，为一个或多个远程 Linux 主机提供基于 SSH 反向隧道的账号级代理。
>
> English: Use one Windows machine running Clash to provide an account-wide proxy for one or more remote Linux hosts through SSH reverse tunnels.
>
> [中文](#中文) · [English](#english)

## UI preview / 界面预览

The desktop manager is a React/Vite dashboard with separate **Overview**,
**Targets**, **Activity**, and **Settings** pages. It supports English and
Chinese through the `EN / 中` switch. These screenshots come from the built-in
`?demo=1` preview mode and use documentation-only sample addresses; they do not
connect to a Linux host or contain real credentials.

桌面管理器使用 React/Vite 构建，提供独立的“总览”“目标主机”“活动记录”和“设置”页面，
通过右上角 `EN / 中` 切换中英文。以下截图来自内置的 `?demo=1` 预览模式，使用文档保留地址，
不会连接真实 Linux 主机，也不包含真实凭据。

<p align="center">
  <img src="docs/screenshots/overview-en.png" alt="Clash SSH Proxy Manager overview dashboard" width="820">
</p>
<p align="center"><sub>Overview / 总览 — local Clash endpoint, tunnel health, and quick insight.</sub></p>

<p align="center">
  <img src="docs/screenshots/targets-en.png" alt="Managed Linux targets page" width="820">
</p>
<p align="center"><sub>Targets / 目标主机 — inspect SSH status, scheduled tasks, proxy health, and access controls.</sub></p>

<p align="center">
  <img src="docs/screenshots/targets-zh-details.png" alt="Chinese target details drawer" width="820">
</p>
<p align="center"><sub>Target details / 目标详情 — open a target without leaving the target list.</sub></p>

<p align="center">
  <img src="docs/screenshots/activity-zh.png" alt="Chinese activity log page" width="820">
</p>
<p align="center"><sub>Activity / 活动记录 — review health checks, tunnel changes, and manager events.</sub></p>

<p align="center">
  <img src="docs/screenshots/add-target-en.png" alt="Add Linux target wizard" width="820">
</p>
<p align="center"><sub>Add target / 新增目标 — guided connection details, SSH key setup, and installation verification.</sub></p>

## 中文

### 项目简介

本项目让一台运行 Clash 的 Windows 电脑，通过 SSH 反向隧道为一个或多个远程 Linux 主机提供
账号级代理。每台 Linux 主机拥有独立的持久 SSH 连接和 Windows 计划任务；不同主机可以使用
相同的远端代理端口，因为端口位于不同机器上。

```text
Linux 主机 A ─┐
Linux 主机 B ─┼─ SSH 反向隧道 ─> Windows 127.0.0.1:7897 ─> Clash ─> Internet
Linux 主机 C ─┘
```

桌面管理器和 PowerShell CLI 共用同一份私有配置以及同一套任务管理命令。

### 核心能力

- React/Vite 桌面仪表盘：总览、目标主机、活动记录、设置分别独立，支持中英文切换。
- 多目标管理：每台 Linux 主机拥有独立的目标 ID、计划任务、SSH 隧道和健康状态。
- CLI 在 SSH 公钥登录就绪后可用一条命令新增目标；React UI 提供首次连接的引导式密钥配置，以及更新、启用、禁用、移除。启用/禁用状态会跨 Windows 登录保持。
- React UI 新增目标时会自动创建并预检专属 Ed25519 SSH 密钥；首次公钥安装只需交互输入一次密码，密码不保存。CLI `add` 要求公钥登录已经就绪。
- 后台并发健康检查、启动恢复和远端端口关闭检查，不阻塞其他 UI 操作。
- Linux 端的 `HTTP_PROXY`、`HTTPS_PROXY`、`NO_PROXY` 以及 Node.js 环境代理支持。
- Windows 计划任务和 SSH 启动器默认无窗口运行，代理端点始终只监听回环地址。

### 安全模型

- Linux 代理端点固定为 `127.0.0.1`，不会监听 `0.0.0.0`。
- 密码不会作为命令行参数传入，也不会写入磁盘。
- 持久隧道必须使用 SSH 公钥认证，并启用 `StrictHostKeyChecking=yes`。
- 新增目标或修改任务名时不会覆盖无关的 Windows 计划任务；任务迁移会先停止并注销旧任务。
- Windows `targets` 列表控制每个目标的访问状态；禁用一个目标只会停止和禁用它自己的隧道。
- 默认配置位于 `%LOCALAPPDATA%\ClashSshProxy\config.json`，不写入 Git 工作区。
- 无窗口计划任务启动器位于 `%ProgramData%\ClashSshProxy\tasks`，仅 Administrators 和 SYSTEM 可写。
- SSH 私钥、应用令牌、Codex `auth.json` 和远程备份禁止提交到仓库。

### 环境要求

Windows 控制端：

- Windows 10 或 11
- PowerShell 5.1 或更高版本
- Windows OpenSSH Client（`ssh.exe`、`scp.exe`）
- 监听回环地址的 Clash 或其他兼容 HTTP 的混合代理
- 修改计划任务时使用管理员 PowerShell
- 只有从源码重建 React UI 时才需要 Node.js 20+ 和 npm

Linux 目标端：

- Bash
- OpenSSH server
- `curl` 及标准 GNU 用户态工具
- 可访问的 SSH 账号，不要求 root

### 一键部署（推荐）

如果目标 Linux 账号已经可以使用 SSH 公钥免密登录，在仓库根目录打开管理员 PowerShell，执行下面一条
`add` 命令即可完成 Linux 集成安装、Windows 计划任务创建、反向隧道启动、代理验证和配置保存：

```powershell
.\proxy-manager.ps1 add `
  -Name development-server `
  -RemoteHost linux.example.com `
  -RemoteUser linuxuser `
  -LocalProxyPort 7897 `
  -RemoteProxyPort 17897
```

#### 首次连接：先准备一次 SSH 公钥

`add` 不接收 Linux 密码。第一次连接时，先为这个目标固定一个唯一的 `-TargetId`，并在
`prepare-ssh`、`bootstrap-key` 和 `add` 三个命令中复用它；否则每次命令都会生成不同的目标 ID
和私钥：

```powershell
$targetId = 'tgt-development-server-001'

.\proxy-manager.ps1 prepare-ssh `
  -TargetId $targetId `
  -Name development-server `
  -RemoteHost linux.example.com `
  -RemoteUser linuxuser

.\proxy-manager.ps1 bootstrap-key `
  -TargetId $targetId `
  -Name development-server `
  -RemoteHost linux.example.com `
  -RemoteUser linuxuser

.\proxy-manager.ps1 add `
  -TargetId $targetId `
  -Name development-server `
  -RemoteHost linux.example.com `
  -RemoteUser linuxuser `
  -LocalProxyPort 7897 `
  -RemoteProxyPort 17897
```

`prepare-ssh` 只在 Windows 创建/修复该目标专属的 Ed25519 私钥并预检登录；`bootstrap-key` 在需要时
打开 SSH 交互，输入一次 Linux 密码，把公钥追加到该账号的 `authorized_keys`。密码不会保存，私钥
不会上传，公钥登录准备完成后再执行 `add`。如果 SSH 端口不是 22，把相同的 `-SshPort` 同时加到
三个命令中。

`add` 不会覆盖已经占用的 `host + user`、计划任务名或私钥路径。已有公钥登录时，可以直接使用上面
第一段的一条命令完成部署。

### 通过 UI 配置

默认入口是 React/Vite 管理器。双击 `Open-ProxyManager.vbs`，或运行
`Open-ProxyManager-React.cmd`；UAC 管理员权限提示属于正常安全确认。首次连接需要安装公钥时，
程序才会另外打开一个临时 PowerShell 窗口输入一次 Linux 密码。

新增目标向导按“连接信息 → SSH 密钥配置 → 安装并验证”进行：

1. 进入“目标主机”页面，点击“添加目标”。
2. 填写目标名称、Linux 主机/IP、Linux 用户、SSH 端口、远端代理端口；计划任务名和额外
   `NO_PROXY` 按需修改。
3. “高级 SSH 设置”中的私钥路径可以留空，管理器会根据目标 ID 使用独立的 Ed25519 私钥；
   只有使用外部密钥时才填写这个路径。
4. 点击“继续检查 SSH”。如果公钥登录已经可用，会直接进入下一步；否则点击“打开 SSH 配置”，
   在临时 PowerShell 窗口输入一次 Linux 密码。窗口完成后点击“验证 SSH”。
5. SSH 验证通过后，向导执行“安装并验证”：安装 Linux 集成、创建计划任务、启动隧道并检查
   代理状态。失败时可以返回修改连接信息或重试安装。

密码只在首次安装 Linux 公钥时临时使用，不会传给界面、写入配置或提交到仓库。完成后可以在
“目标主机”页面编辑、启用、重启或禁用单个目标，在“活动记录”页面查看日志，并在“设置”页面
切换中英文。刷新只读取本地状态；需要连接 Linux 时再点击“健康检查”。

若 React 构建产物缺失，或需要开发前端：

```powershell
Push-Location web
npm install
npm run build
Pop-Location
```

详见 [英文 Windows UI 指南](docs/WINDOWS-UI.en-US.md) / [中文 Windows UI 指南](docs/WINDOWS-UI.zh-CN.md)。

### 已有安装与多台主机

已有 Linux 集成和可用计划任务时，可以用 `adopt` 只登记目标而不重复安装，然后执行一次
`update` 迁移到仓库管理的文件布局：

```powershell
.\proxy-manager.ps1 adopt `
  -Name existing-server `
  -RemoteHost linux.example.com `
  -RemoteUser linuxuser `
  -TaskName ClashProxyToExistingServer
.\proxy-manager.ps1 update -Name existing-server
```

每台主机执行一次 `add`，每台主机都有独立任务；更新或禁用一台不会停止其他主机：

```powershell
.\proxy-manager.ps1 add -Name server-a -RemoteHost server-a.example.com -RemoteUser alice
.\proxy-manager.ps1 add -Name server-b -RemoteHost server-b.example.com -RemoteUser bob
.\proxy-manager.ps1 update-all
.\proxy-manager.ps1 disable -Name server-b
.\proxy-manager.ps1 enable -Name server-b
```

`enable`、`disable` 是公开的隧道状态控制。禁用会停止并禁用目标任务、清理匹配的受管 SSH
进程、保存禁用状态，并在后台确认远端端口已关闭。`BLOCKED` 表示已确认关闭，`LEAK` 表示
端口仍开放，`UNKNOWN` 表示 SSH 不可达。`disable` 不是 Linux 防火墙；Linux 仍可能通过
其他直连路线访问互联网。

### 配置与 SSH 密钥管理

默认私有配置文件：

```text
%LOCALAPPDATA%\ClashSshProxy\config.json
```

也可以用 `-Config PATH` 指定配置文件。配置以无 BOM UTF-8 读写，未知字段、控制字符、非整数
端口和类型不匹配都会被拒绝。新目标获得稳定的 `tgt-...` ID，并使用：

```text
%LOCALAPPDATA%\ClashSshProxy\keys\<target-id>.ed25519
```

对应的 `.pub` 文件会作为 Linux 账号的 `authorized_keys` 公钥。目标 ID 和私钥路径不会与其他
目标共享。精确重复判断使用 `host + user`；SSH 端口只是连接参数，不是目标唯一性的一部分。
每个目标必须使用不同的私钥路径。

`identityManaged` 用于标记由管理器生成的密钥。移除目标时会删除 Windows 任务、Linux 集成和
远端公钥；对于管理器生成的专属私钥，UI 会提示是否同时删除本机私钥和 `.pub` 文件。手工指定
的外部私钥不会被自动删除，Linux 账号本身也不会删除。

配置示例：

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

目标级字段包括 `id`、`enabled`、`sshPort`、`identityFile`、`identityManaged`、
`remoteProxyPort`、`noProxyExtra` 和 `taskName`。旧配置仍可读取 `defaults.identityFile`，
但新目标不会使用共享的默认私钥。

### 命令

| 命令 | 用途 |
|---|---|
| `prepare-ssh` | 创建/修复本机密钥并静默检查免密登录 |
| `bootstrap-key` | 交互式把 Windows 公钥追加到 Linux 账号 |
| `add` | 安装并启动新目标，然后写入管理配置 |
| `adopt` | 登记已可用目标，不修改 Linux |
| `status` | 检查计划任务、SSH 和远端代理健康度 |
| `enable` | 持久启用并启动一个目标 |
| `disable` | 持久禁用并停止一个目标 |
| `update` | 幂等重装目标并刷新计划任务 |
| `update-all` | 更新所有已登记目标 |
| `install-all` | 批量安装/更新所有已登记目标 |
| `reconcile` | 等待 Clash 就绪后恢复已启用但已停止的目标 |
| `remove` | 删除任务、Linux 集成和远端公钥；UI 可额外删除专属本机私钥 |
| `validate-config` | 校验 JSON 结构和参数范围 |

运行 `.\proxy-manager.ps1 help` 查看紧凑的命令参考。

### Linux 安装布局

生成的运行时配置与源码目录分离：

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

安装器会在 Bash 启动文件前部维护一个受管区块；重复执行会替换原区块而不是追加副本。
符号链接会被保留，悬空链接和格式错误的受管区块会在修改前被拒绝。

```bash
proxy_status
proxy_off
proxy_on
```

新 Bash 登录会话以及从中启动的程序会继承代理环境。`sudo`、systemd、cron、Docker 和其他
用户不一定继承这些变量，需要单独配置。集成还会导出 `NODE_USE_ENV_PROXY=1`，使支持环境代理
的 Node.js 版本使用 `HTTP_PROXY`、`HTTPS_PROXY` 和 `NO_PROXY`；执行 `proxy_off` 会一并移除
代理变量和 Node.js 开关。

### 故障行为

计划任务在登录后延迟 15 秒启动；无窗口启动器会在 SSH 失败后每 5 秒重试，任务计划程序还保留
一分钟级的备用重启策略。Windows 关机、注销、Clash 停止、网络中断或 SSH 任务无法连接时，
对应 Linux 主机会失去代理，其他目标仍独立运行。

新增和更新采用失败关闭策略：管理员权限和任务名冲突会在修改 Linux 前检查；启动、验证或保存
失败时会停止并注销替换隧道，首次安装会回滚到可恢复的备份目录。未登记但已存在的 Linux 集成
不会被 `add` 覆盖，应先 `adopt` 或运行 Linux 卸载脚本。

### 代码组织

根目录 CLI/UI 脚本是稳定的薄入口；实现位于 `src`，按配置、SSH 传输、Windows 隧道生命周期、
Linux 操作、UI 运行时、健康检查和对话框分组。React 源码在 `web/src`，UI 烟雾测试位于
`tests`，不混入生产入口。

详见 [中文架构指南](docs/ARCHITECTURE.zh-CN.md)。

### 开发与测试

Linux 测试：

```bash
bash tests/test-linux.sh
```

PowerShell 解析、配置、任务回滚、进程匹配、UTF-8、JSON 状态和 Windows UI 烟雾测试：

```powershell
.\tests\Test-Manager.ps1
```

测试应在 Windows PowerShell 5.1 和 PowerShell 7 中运行。GitHub Actions 会在 push 和 pull request
上执行 Windows、Linux 和仓库隐私检查；`tests/test-privacy.sh` 会拒绝跟踪的私钥、凭据样值、
私有地址和敏感状态文件名。

## English

### Overview

This project uses one Windows machine running Clash to provide an account-wide proxy for one or more
remote Linux hosts through loopback-only SSH reverse tunnels. Each Linux host has its own persistent
SSH connection and Windows scheduled task. Remote port `17897` may be reused because it is local to
each different Linux machine.

```text
Linux host A ─┐
Linux host B ─┼─ SSH reverse tunnels ─> Windows 127.0.0.1:7897 ─> Clash ─> Internet
Linux host C ─┘
```

The Windows desktop manager and PowerShell CLI share the same private configuration and task-management
commands.

### Features

- React/Vite dashboard with separate Overview, Targets, Activity, and Settings pages plus EN/中文 switching.
- Independent target IDs, scheduled tasks, SSH tunnels, keys, and health state for multiple Linux hosts.
- Add, adopt, update, enable, disable, and remove targets without affecting unrelated hosts. The CLI `add` command is the one-command installer once public-key login is ready; the React UI guides first-time SSH setup.
- The React UI automatically prepares a dedicated Ed25519 identity and preflights public-key login; a Linux password is requested interactively once only when needed and is never stored. CLI `add` requires key login to be ready.
- Concurrent background health checks, startup recovery, and remote-port closure verification keep the UI responsive.
- Linux `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY`, and `NODE_USE_ENV_PROXY=1` support for Node.js releases with environment-proxy support.
- Windowless Windows scheduled-task launchers and loopback-only proxy endpoints by default.

### Security model

- The Linux proxy endpoint is fixed to `127.0.0.1`; it is never exposed on `0.0.0.0`.
- Passwords are never accepted as command-line parameters or written to disk.
- Persistent tunnels require SSH public-key authentication and `StrictHostKeyChecking=yes`.
- Adding a target or changing its task name refuses to overwrite an unrelated scheduled task; migrations stop and unregister the old task first.
- The Windows `targets` list controls per-target access. Disabling one target stops and disables only its own tunnel.
- Machine-specific hosts, users, ports, and key paths default to `%LOCALAPPDATA%\ClashSshProxy\config.json`, outside the repository.
- Windowless launchers live under `%ProgramData%\ClashSshProxy\tasks`, writable only by Administrators and SYSTEM.
- Private keys, application tokens, Codex `auth.json`, and remote shell backups must never be committed.

### Requirements

Windows controller:

- Windows 10 or 11
- PowerShell 5.1+
- Windows OpenSSH Client (`ssh.exe`, `scp.exe`)
- Clash or another HTTP-compatible mixed proxy listening on loopback
- Administrator PowerShell for scheduled-task changes
- Node.js 20+ and npm only when rebuilding the React UI

Linux target:

- Bash
- OpenSSH server
- `curl` and standard GNU userland tools
- A reachable SSH account; root is not required

### One-click deployment (recommended)

When the Linux account already accepts SSH public-key authentication, open an elevated PowerShell window
in the repository root and run this one `add` command. It installs the Linux integration, creates the
Windows scheduled task, starts the reverse tunnel, verifies the proxy, and saves the target:

```powershell
.\proxy-manager.ps1 add `
  -Name development-server `
  -RemoteHost linux.example.com `
  -RemoteUser linuxuser `
  -LocalProxyPort 7897 `
  -RemoteProxyPort 17897
```

#### First connection: prepare SSH public-key login once

`add` does not accept a Linux password. For a first connection, choose one unique `-TargetId` and reuse it
with all three commands—`prepare-ssh`, `bootstrap-key`, and `add`. Otherwise each command creates a different
target ID and private key:

```powershell
$targetId = 'tgt-development-server-001'

.\proxy-manager.ps1 prepare-ssh `
  -TargetId $targetId `
  -Name development-server `
  -RemoteHost linux.example.com `
  -RemoteUser linuxuser

.\proxy-manager.ps1 bootstrap-key `
  -TargetId $targetId `
  -Name development-server `
  -RemoteHost linux.example.com `
  -RemoteUser linuxuser

.\proxy-manager.ps1 add `
  -TargetId $targetId `
  -Name development-server `
  -RemoteHost linux.example.com `
  -RemoteUser linuxuser `
  -LocalProxyPort 7897 `
  -RemoteProxyPort 17897
```

`prepare-ssh` creates or repairs the target-specific Ed25519 private key on Windows and preflights login.
When needed, `bootstrap-key` opens an interactive SSH flow: enter the Linux password once to append the
public key to that account's `authorized_keys`. The password is never stored and the private key is never
uploaded. Run `add` after public-key login is ready. If SSH uses a non-default port, pass the same
`-SshPort` to all three commands.

`add` refuses collisions with an existing `host + user`, scheduled-task name, or private-key path. When
public-key login is already ready, the first command above is the complete one-command deployment.

### Configure through the UI

The default entry point is the React/Vite manager. Double-click `Open-ProxyManager.vbs`, or run
`Open-ProxyManager-React.cmd`; the UAC administrator prompt is an expected security confirmation. A
temporary PowerShell window appears only when the first connection needs the Linux public key installed,
so that the one-time Linux password can be entered.

The Add target wizard follows “Connection details → SSH key setup → Install & verify”:

1. Open the **Targets** page and click **Add target**.
2. Enter the target name, Linux host/IP, Linux user, SSH port, and remote proxy port. Adjust the scheduled
   task name and extra `NO_PROXY` entries only when needed.
3. Leave the private-key path under **Advanced SSH settings** empty to use the target ID's dedicated
   Ed25519 key. Fill it only when an external identity file is required.
4. Click **Continue to SSH check**. If public-key login is ready, the wizard proceeds; otherwise click
   **Open SSH setup** and enter the Linux password once in the temporary PowerShell window. After it
   finishes, click **Verify SSH**.
5. After SSH verification, the wizard runs **Install & verify**: it installs the Linux integration, creates
   the scheduled task, starts the tunnel, and checks the proxy. If installation fails, edit the connection
   details or retry.

The password is used only for the first Linux public-key installation. It is never sent to the UI, written
to configuration, or committed to the repository. Afterwards, use **Targets** to edit, enable, restart, or
disable one target; **Activity** to inspect logs; and **Settings** to switch languages. Refresh reads local
state only; click **Health check** when Linux connectivity must be tested.

If the checked-in React bundle is missing or the frontend is being developed:

```powershell
Push-Location web
npm install
npm run build
Pop-Location
```

See the [English Windows UI guide](docs/WINDOWS-UI.en-US.md) / [Chinese Windows UI guide](docs/WINDOWS-UI.zh-CN.md).

### Existing installations and multiple hosts

Use `adopt` to record an already-working Linux integration and task without reinstalling it, then run
`update` once to move it to the repository-managed layout:

```powershell
.\proxy-manager.ps1 adopt `
  -Name existing-server `
  -RemoteHost linux.example.com `
  -RemoteUser linuxuser `
  -TaskName ClashProxyToExistingServer
.\proxy-manager.ps1 update -Name existing-server
```

Run `add` once per host. Each host receives an independent task; updating or disabling one does not stop
the others:

```powershell
.\proxy-manager.ps1 add -Name server-a -RemoteHost server-a.example.com -RemoteUser alice
.\proxy-manager.ps1 add -Name server-b -RemoteHost server-b.example.com -RemoteUser bob
.\proxy-manager.ps1 update-all
.\proxy-manager.ps1 disable -Name server-b
.\proxy-manager.ps1 enable -Name server-b
```

`enable` and `disable` are the public tunnel state controls. Disable stops/disables the target task,
cleans matching managed SSH processes, saves the disabled state, and verifies the remote port in the
background. `BLOCKED` confirms closure; `LEAK` means the port remains open; `UNKNOWN` means SSH could
not confirm it. Disable is not a Linux firewall, so another direct route may still reach the Internet.

### Configuration and SSH identity management

The default private state file is:

```text
%LOCALAPPDATA%\ClashSshProxy\config.json
```

Use `-Config PATH` to choose another file. Configuration is read and written as BOM-less UTF-8; unknown
fields, control characters, non-integral ports, and mismatched types are rejected. New targets receive
a stable `tgt-...` ID and a dedicated identity at:

```text
%LOCALAPPDATA%\ClashSshProxy\keys\<target-id>.ed25519
```

The matching `.pub` file is installed as the Linux account's `authorized_keys` public key. Target IDs
and key paths are never shared. Exact duplicate detection uses `host + user`; SSH port is a connection
setting, not target identity. Every target must have a different private-key path.

`identityManaged` marks manager-generated keys. Removing a target removes its Windows task, Linux
integration, and remote public key. For a dedicated manager-generated key, the UI asks whether the
local private key and `.pub` file should also be deleted. Manually specified external keys are kept;
the Linux account itself is never deleted.

The JSON shape is the same as the example in the Chinese section above. Target-level fields are `id`,
`enabled`, `sshPort`, `identityFile`, `identityManaged`, `remoteProxyPort`, `noProxyExtra`, and
`taskName`. Legacy `defaults.identityFile` remains readable, but new targets do not use a shared default
private key.

### Commands

The command set is shared by the Chinese and English documentation:

| Command | Purpose |
|---|---|
| `prepare-ssh` | Create/repair the local identity and silently check key login |
| `bootstrap-key` | Interactively append the Windows public key to one Linux account |
| `add` | Install and start a new target, then save it in the manager config |
| `adopt` | Record an already-working target without changing it |
| `status` | Check scheduled tasks, SSH, and remote proxy health |
| `enable` | Enable and start one target persistently |
| `disable` | Disable and stop one target persistently |
| `update` | Reinstall one target idempotently and refresh its task |
| `update-all` | Update every recorded target |
| `install-all` | Install/update every recorded target |
| `reconcile` | Wait briefly for Clash, then recover stopped enabled targets |
| `remove` | Remove one task, Linux integration, and the matching remote public key; the UI can also remove its dedicated local key |
| `validate-config` | Validate JSON structure and parameter ranges |

Run `.\proxy-manager.ps1 help` for a compact command reference.

### Linux installation layout

Generated runtime configuration is kept separate from the source checkout:

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

The installer maintains one managed block near the beginning of active Bash startup files. Re-running
it replaces that block instead of appending duplicates. Symlinks are preserved; dangling links and
malformed managed blocks are rejected before changes are made.

```bash
proxy_status
proxy_off
proxy_on
```

New Bash login sessions and programs launched from them inherit the proxy environment. `sudo`, systemd,
cron, Docker, and other users may need separate configuration. The integration also exports
`NODE_USE_ENV_PROXY=1` so Node.js releases with environment-proxy support use `HTTP_PROXY`, `HTTPS_PROXY`,
and `NO_PROXY`; `proxy_off` removes the variables and the Node.js opt-in.

### Failure behavior

The scheduled task starts 15 seconds after logon. Its windowless launcher retries a failed SSH tunnel
after five seconds, while Task Scheduler retains a one-minute fallback restart policy. A Linux host
loses proxy access when Windows is off or logged out, Clash is stopped, the network is unavailable, or
its SSH task cannot connect; other configured hosts continue independently.

Add and update fail closed. Administrator and task-name collision checks run before Linux is modified.
If task startup, proxy verification, or configuration saving fails, the replacement tunnel is stopped
and unregistered; a first-time installation rolls back to a recoverable archived directory. An existing
Linux integration not recorded by the manager is not overwritten by `add`; adopt it or run the Linux
uninstaller first.

### Code organization

The root CLI and UI scripts are intentionally small entry points. Implementation lives under `src`,
grouped by configuration, SSH transport, Windows tunnel lifecycle, Linux operations, UI runtime, health
checks, and dialogs. React source is under `web/src`; UI smoke tests remain under `tests`.

See the [Chinese architecture guide](docs/ARCHITECTURE.zh-CN.md) for module dependency rules and the
location for future SSH bootstrap work.

### Development and tests

Linux tests:

```bash
bash tests/test-linux.sh
```

PowerShell parser, configuration, rollback, process-identity, UTF-8, JSON-status, and Windows UI smoke
tests:

```powershell
.\tests\Test-Manager.ps1
```

Run the suite in both Windows PowerShell 5.1 and PowerShell 7. GitHub Actions runs Windows, Linux, and
repository-privacy checks for pushes and pull requests. `tests/test-privacy.sh` rejects tracked private
keys, credential-like values, private addresses, and sensitive state-file names.