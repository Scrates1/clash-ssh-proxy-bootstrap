# Windows 管理界面使用说明

## 打开方式

双击仓库根目录的 `Open-ProxyManager.cmd`，在 Windows 权限提示中选择“是”。
界面需要管理员权限来创建、启动、停止和禁用计划任务。

启动器旁边的 PowerShell 窗口用于显示一次性 SSH 密码提示和诊断信息。
关闭该 PowerShell 窗口会同时关闭管理界面。0.2.4 起，隧道计划任务通过真正无窗口
的启动器运行，点击 Enable proxy 不会再创建或闪现 SSH 黑色控制台窗口。
启动器保存在 `%ProgramData%\ClashSshProxy\tasks`，仅 Administrators 和 SYSTEM
可访问，避免普通进程篡改最高权限计划任务。

## 顶部与表格状态

- `Local proxy [UP]`：Windows 上的 Clash 端口正在监听。
- `Local proxy [DOWN]`：Clash 未启动，或配置的本地端口不正确。
- `Enabled`：该 Linux 是否处于长期启用状态；可直接点击复选框切换。
- `Task`：Windows 计划任务状态，常见值为 `Running`、`Ready`、`Disabled`。
- `SSH`：Windows 到 Linux 的 SSH 公钥连接是否正常。
- `Proxy`：代理状态。
  - `OK`：代理实际可用。
  - `CHECKING`：隧道已启动，界面正在后台进行端到端验证。
  - `FAIL`：目标处于允许状态，但代理检测失败。
  - `DISABLED`：快速刷新确认目标配置为禁用；尚未做远端检查。
  - `BLOCKED`：深度检查确认远端代理端口已经关闭。
  - `LEAK`：目标配置为禁止，但远端端口仍然开放，需要立即排查其他隧道。
  - `UNKNOWN`：Linux 离线或 SSH 不可达，无法远端确认。

灰色行表示长期禁止。淡红色行表示目标允许，但任务未运行。红色行表示检测到
`LEAK`。

## 按钮说明

### Add target

添加并安装一台 Linux。它会上传 Linux 端文件、创建独立计划任务、启动隧道并
验证代理。新 Linux 尚未配置公钥时，可勾选先安装 SSH 公钥；密码只在控制台中
输入一次，不会保存。

### Edit / Update

修改目标参数并重新部署 Linux 文件和 Windows 计划任务。更新期间该目标会短暂
断线，其他目标不受影响。

### Enable proxy / Disable proxy

主界面的动态按钮和表格最左侧 `Enabled` 复选框执行相同操作。可直接点击，无需确认
弹窗；操作成功后也不会再弹成功提示，只有同步启动失败时才会弹出错误信息：

- 当前为禁止状态时显示 `Enable proxy`：长期允许所选 Linux 使用代理，立即启动
  隧道；确认本机 Clash、计划任务和受管 SSH 进程已启动后立即返回。随后该行显示
  `CHECKING`，界面通过隐藏的后台进程只验证所选目标；完成后变为 `OK` 或 `FAIL`。
  后台验证期间其他按钮和目标仍可操作。Windows 下次登录时计划任务会自动启动。
- 当前为允许状态时显示 `Disable proxy`：长期禁止所选 Linux 使用这台 Windows
  的 Clash 代理。它会：

1. 停止并禁用该目标的计划任务；
2. 清理与该目标匹配的残留 SSH 反向隧道进程；
3. 保存禁止状态；
4. Linux 在线时，直接验证远端代理端口已经关闭。

Disable 命令会自行验证端口关闭；需要刷新所有目标的 SSH/代理状态时可手动点击
Health check，表格显示 `BLOCKED` 表示远端端口已确认关闭。
`Disable proxy` 不是 Linux 防火墙：如果 Linux 本身具有无需此代理的直连网络，
它仍然可以直接联网。

`Disable proxy` 不会卸载 Linux 文件。Linux 已打开的终端中仍可能保留
`HTTP_PROXY` 等环境变量，但这些变量指向的端口已不可用，所以联网命令会失败。
需要临时直连时，在 Linux 当前终端运行 `proxy_off`。

### Advanced...

低频维护操作集中在这里：

- `Install SSH key`：把 Windows SSH 公钥追加到所选 Linux 账号。必要时会在
  PowerShell 窗口要求输入一次 Linux 密码；不会复制或保存私钥、密码。
- `Refresh local status`：只读取 Windows 本地配置、Clash 端口和计划任务状态，
  不连接 Linux，速度较快。
- `Remove target`：删除 Windows 计划任务、私有目标配置和 Linux 账号的代理
  Shell 集成，适用于不再管理这台 Linux 的情况。

### Health check

连接每台 Linux，实际检查 SSH、代理可用性或禁止状态。不可达主机可能等待数秒。
这是手动的全量端到端检查；`BLOCKED` 表示禁用状态已从远端得到确认。

### Help

打开本说明文档。

## 常见问题

### 为什么没有 Start / Stop

它们会制造“允许但没有运行”等中间状态，容易与 Enable/Disable 混淆。0.2.3 起，
界面和公开命令行只提供 `enable` 与 `disable`；内部启停计划任务仍由程序自动完成。

### Enable / Disable 为什么以前较慢

旧版本在命令已经验证结果后，界面还会重复执行完整 Health check。0.2.4 已取消重复检查，
并合并禁用状态的 SSH 与端口探测。0.2.6 起，Enable 的端到端代理检查转入隐藏后台，
按钮只等待本机启动检查；需要所有目标的最新全量状态时仍可手动点击 Health check。
Disable 仍会等待远端端口确认关闭，因此通常比 Enable 稍慢。

### 为什么开启后目标行以前会消失一下再出现

旧界面每次刷新都会先清空整张表，再重新添加所有目标。0.2.6 改为保留现有行并原地更新，
同时启用表格双缓冲；目标行、勾选框和当前选择不会再在 Enable 后短暂消失。

### Disable proxy 后 Linux 命令无法联网

这是预期行为：Linux 终端仍在尝试连接已被关闭的代理端口。运行 `proxy_off` 可在
当前终端临时改为直连；再次点击 Enable proxy 后，新旧终端都可以继续通过代理。

### Proxy 显示 FAIL

确认 Windows Clash 正在运行且顶部显示 `[UP]`，然后点击 Enable proxy，再运行
Health check。也要确认 Windows 能通过 SSH 公钥登录目标 Linux。

0.2.5 起，健康检查会依次尝试 Gstatic、Cloudflare 和 Google，单个站点故障不会再把
整个代理误报为 FAIL。健康检查为 OK 只表示代理链路可用，不保证每一个网站都可访问；
如果只有 Google 等特定网站失败，请在 Clash 中检查当前节点和分流规则。

### Proxy 显示 LEAK

说明禁止状态与远端实际端口不一致。先检查是否存在其他手工建立的反向隧道或其他
Windows 控制端。重新启用后再点击 Disable proxy，会再次清理本机匹配的受管隧道。

### 日志出现乱码或颜色控制字符

关闭旧界面并使用 `Open-ProxyManager.cmd` 重新打开。0.2.2 起，启动器、Windows
PowerShell 和 SSH/SCP 输出统一使用 UTF-8，日志框也会移除 ANSI 颜色控制字符。

## 控制边界

本工具按 Linux 主机允许或禁止，不按网站、URL、Linux 进程分别授权。远端端口只
监听 Linux 的 `127.0.0.1`，不会暴露给局域网中的其他机器；但同一 Linux 上知道
端口的其他本地账号仍可能主动连接，严格的多账号隔离需要额外的 Linux 防火墙或
账号隔离策略。它也不会阻止 Linux 使用自身的直连网络。
