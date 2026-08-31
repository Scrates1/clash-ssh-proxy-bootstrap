# clash-ssh-proxy-bootstrap

> 中文：在一台 Windows 电脑上，通过 Clash 和 SSH 反向隧道管理远程 Linux 主机的代理访问。
>
> English: Manage proxy access for remote Linux hosts from one Windows PC through Clash and SSH reverse tunnels.
>
> [中文](#中文) · [English](#english)

## 先说结论 / TL;DR

不需要部署 Web 服务，也不需要安装 Node.js。当前仓库已经包含 React UI 的构建产物：

1. 从 GitHub 下载 ZIP：[下载当前版本](https://github.com/Scrates1/clash-ssh-proxy-bootstrap/archive/refs/heads/main.zip)。
2. 解压到本机任意目录。
3. 双击 Open-ProxyManager.vbs。
4. 在 UI 中添加目标主机、完成 SSH 一次性配置，然后启动隧道。

管理器本身只在这台 Windows 电脑本地运行，桥接服务只监听 127.0.0.1。第一次在 UI 中添加
Linux 目标时，向导会在远端安装必要的代理脚本、创建 Windows 计划任务并启动隧道；这属于
“接入目标主机”，不是部署一个额外的 Web 服务。

No web server deployment or Node.js installation is required for normal use. The repository already
contains the built React UI:

1. Download the [current ZIP package](https://github.com/Scrates1/clash-ssh-proxy-bootstrap/archive/refs/heads/main.zip).
2. Extract it to any local folder.
3. Double-click Open-ProxyManager.vbs.
4. Add targets, complete the one-time SSH setup in the UI, and start the tunnels.

The manager runs locally on Windows and its bridge listens only on 127.0.0.1. When the UI adds a Linux
target for the first time, it installs the required remote proxy scripts, creates the Windows scheduled
task, and starts the tunnel. That is target onboarding, not deployment of a separate web service.

## UI preview / 界面预览

这些截图来自内置的 demo 预览模式，地址和日志都是文档专用示例，不会连接真实 Linux 主机，
也不包含真实凭据。它们对应正常用户的 UI 操作顺序。

These screenshots come from the built-in demo preview. Addresses and logs are documentation-only
examples; they do not connect to a real Linux host or contain real credentials.

<p align="center">
  <img src="docs/screenshots/overview-en.png" alt="Overview dashboard / 总览" width="820">
</p>
<p align="center"><sub>1. Overview / 总览：确认本机 Clash 端点和所有隧道的整体状态。</sub></p>

<p align="center">
  <img src="docs/screenshots/targets-en.png" alt="Targets page / 目标主机" width="820">
</p>
<p align="center"><sub>2. Targets / 目标主机：查看连接、任务、代理健康度和启用状态。</sub></p>

<p align="center">
  <img src="docs/screenshots/add-target-en.png" alt="Add target wizard / 新增目标向导" width="820">
</p>
<p align="center"><sub>3. Add target / 新增目标：按连接信息、SSH 密钥、安装验证三步完成接入。</sub></p>

<p align="center">
  <img src="docs/screenshots/targets-zh-details.png" alt="Target details / 目标详情" width="820">
</p>
<p align="center"><sub>4. Target details / 目标详情：查看单个目标并执行启用、编辑、SSH 配置或移除。</sub></p>

<p align="center">
  <img src="docs/screenshots/activity-zh.png" alt="Activity page / 活动记录" width="820">
</p>
<p align="center"><sub>5. Activity / 活动记录：查看健康检查、隧道变化和管理器操作日志。</sub></p>

## 中文

### 当前支持范围

当前版本支持 Windows 作为控制端；Linux 是被管理的目标主机。Linux/macOS 控制端暂未接入。

### 运行前准备

控制端需要：

- Windows 10 或 Windows 11。
- Windows PowerShell 5.1 或更高版本。
- Windows OpenSSH Client，包含 ssh.exe 和 scp.exe。
- 正在运行的 Clash 或兼容 HTTP 的混合代理，默认监听 127.0.0.1:7897。
- 首次添加目标时允许 UAC 提权，用于创建 Windows 计划任务。

目标 Linux 主机需要：

- 可访问的 SSH 账号，不需要 root。
- OpenSSH server、Bash、curl 和标准 GNU 工具。
- Windows 能够通过 SSH 连接到该账号。

### 下载并启动

1. 打开上面的 GitHub ZIP 下载链接，下载后解压。不要只复制某一个脚本，web/dist 目录需要和启动脚本一起保留。
2. 双击 Open-ProxyManager.vbs。它会隐藏 PowerShell 窗口并自动打开本机管理界面。
3. 出现 Windows UAC 提示时选择“是”。这是创建和管理计划任务所需的正常安全确认。
4. 首次启动不需要 npm、Node.js、数据库、Docker 或额外的 Web 服务器。
5. 如果希望使用备用入口，可以打开 Open-ProxyManager.cmd；想要尽量不闪过黑色窗口时，优先使用 VBS。

### 通过 UI 添加目标主机

1. 进入“目标主机”页面，点击“添加目标”。
2. 填写目标名称、Linux 主机/IP、Linux 用户、SSH 端口和远端代理端口。
3. “高级 SSH 设置”中的私钥路径保持为空。管理器会自动为这个目标生成独立的 Ed25519 私钥。
4. 点击“继续检查 SSH”。
5. 如果该 Linux 账号还没有接受公钥，点击“打开 SSH 配置”。程序会打开一个临时 PowerShell
   窗口，只要求输入一次 Linux 密码；密码不会传给 UI、写入配置或保存到磁盘。
6. 回到 UI 点击“验证 SSH”。验证通过后，向导执行“安装并验证”，完成 Linux 集成、Windows
   计划任务、SSH 反向隧道和代理检查。
7. 接入成功后，目标会出现在列表中。每个目标拥有稳定的目标 ID 和独立的本机私钥；精确重复
   判断使用“服务器地址 + 用户名”，SSH 端口只是连接参数。

如果已经配置好 SSH 公钥登录，向导会跳过密码步骤。外部私钥只有在“高级 SSH 设置”中主动
填写时才使用；不同目标不能共享同一个私钥路径。

### 日常使用

- “总览”是主界面：查看本机 Clash 端点、活跃隧道、健康目标和需要关注的目标。
- “目标主机”是独立管理页面：点击目标行打开详情，不会把页面下拉到其他区域。
- 在目标详情中可以编辑连接信息、配置 SSH 登录、启用/禁用代理或移除目标。
- “活动记录”是独立日志页面：查看健康检查、隧道恢复、启用/禁用和移除等事件。
- “设置”中可以切换中文和英文，选择会保存在本机。
- “刷新状态”重新读取管理器当前状态；“健康检查”用于主动验证 SSH、隧道和远端代理链路。
- 启用或禁用一个目标只影响该目标，不会停止其他服务器。
- 移除目标前会明确提示：程序生成的专属私钥默认可以随目标一起删除；手工指定的外部私钥
  会保留。Linux 账号本身不会被删除。

### 私钥和数据保存

- 配置保存在本机：%LOCALAPPDATA%\ClashSshProxy\config.json。
- 管理器生成的私钥保存在本机：%LOCALAPPDATA%\ClashSshProxy\keys\<target-id>.ed25519。
- Windows 只保存私钥；Linux 账号接收对应的公钥。
- 密码只在首次安装公钥时临时使用，不会保存。
- 代理端点只监听 Linux 的 127.0.0.1，不会暴露到 Linux 局域网。
- 当前控制端关闭或 Clash 停止时，远程目标会失去这条代理隧道；其他目标仍独立管理。

### 常见问题

#### 需要部署吗？

不需要部署管理器。下载完整 ZIP、解压、双击 Open-ProxyManager.vbs 即可本地运行。
只有点击“添加目标”后，UI 才会把 Linux 端运行所需的脚本安装到目标主机。

#### 界面打不开怎么办？

确认解压后的目录中仍有 web/dist/index.html 和 web/dist/assets。若下载不完整，请重新下载
完整 ZIP。Node.js 和 npm 只在开发者修改前端并重新构建 UI 时需要，普通使用不需要。

#### 本机代理显示离线怎么办？

先启动 Clash，并确认混合代理监听 127.0.0.1:7897，再回到“总览”点击“刷新状态”。
当前版本默认使用这个本机端口。

#### 为什么首次添加目标会出现 PowerShell 窗口？

这是一次性安装 Linux 公钥的交互窗口。输入密码后关闭或等待窗口完成，再回到向导点击“验证
SSH”；密码不会保存。

#### 为什么删除目标还要确认私钥？

每个目标使用独立私钥。删除专属私钥后无法恢复，因此 UI 会单独询问；外部私钥不会由管理器
自动删除。

更多细节见 [中文 Windows UI 指南](docs/WINDOWS-UI.zh-CN.md)、[英文 Windows UI 指南](docs/WINDOWS-UI.en-US.md)
和 [中文架构说明](docs/ARCHITECTURE.zh-CN.md)。

## English

### Current scope

The current release supports Windows as the controller; Linux hosts are managed targets. A Linux or
macOS controller is not included yet.

### Requirements

Controller:

- Windows 10 or Windows 11.
- Windows PowerShell 5.1+.
- Windows OpenSSH Client, including ssh.exe and scp.exe.
- Clash or another HTTP-compatible mixed proxy listening on 127.0.0.1:7897 by default.
- Permission to approve the UAC prompt when the manager creates scheduled tasks.

Linux target:

- A reachable SSH account; root is not required.
- OpenSSH server, Bash, curl, and standard GNU userland.
- Network access from Windows to that SSH account.

### Download and start

1. Open the GitHub ZIP link above, download it, and extract it. Keep web/dist next to the launcher files.
2. Double-click Open-ProxyManager.vbs. It hides the PowerShell window and opens the local manager UI.
3. Approve the Windows UAC prompt. This is the expected confirmation for scheduled-task management.
4. Node.js, npm, a database, Docker, and a separate web server are not required for normal use.
5. Open-ProxyManager.cmd is available as a fallback launcher. Prefer the VBS entry when you want to avoid
   a visible console flash.

### Add a target through the UI

1. Open **Targets** and click **Add target**.
2. Enter the target name, Linux host/IP, Linux user, SSH port, and remote proxy port.
3. Leave the private-key path under **Advanced SSH settings** empty. The manager creates a dedicated
   Ed25519 identity for this target.
4. Click **Continue to SSH check**.
5. If the Linux account has not accepted the public key, click **Open SSH setup**. A temporary PowerShell
   window asks for the Linux password once; the password is never sent to the UI, written to configuration,
   or saved to disk.
6. Return to the UI and click **Verify SSH**. After verification, the wizard runs **Install & verify**:
   Linux integration, the Windows scheduled task, the reverse SSH tunnel, and the proxy check.
7. The target appears in the list. Each target has a stable target ID and a dedicated local private key.
   Exact duplicate detection uses server address + user; SSH port is a connection setting.

If public-key login is already ready, the password step is skipped. An external identity is used only when
you explicitly fill it under **Advanced SSH settings**; different targets must not share one private-key path.

### Daily UI operations

- **Overview** is the main dashboard for the local Clash endpoint, active tunnels, healthy targets, and attention items.
- **Targets** is a separate management page. Click a target row to open its details; the page does not
  scroll to another section.
- Target details can edit connection data, configure SSH login, enable/disable proxy access, or remove a target.
- **Activity** is a separate log page for health checks, tunnel recovery, enable/disable, and removal events.
- **Settings** switches between English and Chinese and stores the choice locally.
- **Refresh status** reloads the manager's current state; **Health check** actively verifies SSH, tunnel,
  and remote proxy connectivity.
- Enabling or disabling one target affects only that target.
- Removing a target shows an explicit key-deletion choice. A manager-generated dedicated key can be deleted
  with the target; a manually supplied external key is kept. The Linux account itself is never deleted.

### Keys and local data

- Configuration is stored locally at %LOCALAPPDATA%\ClashSshProxy\config.json.
- Manager-generated keys are stored locally at %LOCALAPPDATA%\ClashSshProxy\keys\<target-id>.ed25519.
- Windows keeps the private key; the Linux account receives the matching public key.
- The password is used only during first-time public-key installation and is never stored.
- The proxy endpoint listens only on Linux 127.0.0.1 and is not exposed to the Linux LAN.
- If Windows or Clash is offline, the remote target loses this tunnel; other targets remain independent.

### FAQ

#### Is deployment required?

No manager deployment is required. Download the complete ZIP, extract it, and double-click
Open-ProxyManager.vbs. The manager runs locally. Only the **Add target** wizard installs the scripts
needed by a Linux target.

#### The UI does not open

Make sure the extracted folder still contains web/dist/index.html and web/dist/assets. Re-download the
complete ZIP if necessary. Node.js and npm are needed only when a developer rebuilds the frontend.

#### The local proxy is offline

Start Clash, confirm that its mixed proxy listens on 127.0.0.1:7897, and click **Refresh status** on
**Overview**. The current UI uses this local endpoint by default.

#### Why does a PowerShell window appear during the first connection?

It is the one-time interactive window used to install the Linux public key. Enter the password, wait for
the window to finish, and click **Verify SSH** in the wizard. The password is not saved.

#### Why does removing a target ask about the private key?

Each target has its own private key. A dedicated key cannot be recovered after deletion, so the UI asks
separately. External keys are never deleted automatically.

For more detail, see the [Chinese Windows UI guide](docs/WINDOWS-UI.zh-CN.md), [English Windows UI guide](docs/WINDOWS-UI.en-US.md),
and [Chinese architecture guide](docs/ARCHITECTURE.zh-CN.md).

## Security notes

- The manager bridge is local-only and listens on 127.0.0.1.
- The Linux proxy endpoint is loopback-only.
- Passwords are never stored.
- Persistent SSH tunnels use public-key authentication and strict host-key checking.
- Private keys, credentials, and machine-specific configuration must not be committed to this repository.

## For contributors

The desktop manager is a React/Vite UI with a PowerShell local bridge. Normal users download the checked-in
build and do not need Node.js. Node.js 20+ and npm are only needed when changing web/ or rebuilding the UI.
