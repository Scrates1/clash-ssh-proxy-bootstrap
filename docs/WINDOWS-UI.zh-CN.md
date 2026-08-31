# Windows 管理界面使用说明

English version: [Windows Manager UI Guide](WINDOWS-UI.en-US.md)

当前稳定版本：1.0.0。

## 打开方式

双击仓库根目录的 `Open-ProxyManager.vbs`，可以在不出现黑色控制台窗口的情况下
打开界面；Windows 权限提示出现时选择“是”。界面需要管理员权限来管理计划任务。

`Open-ProxyManager.cmd` 仍可兼容使用，它会立即转交给 VBS 并退出，但 Windows 启动
`.cmd` 时仍可能短暂闪一下 CMD 窗口。管理员权限提示（UAC）属于正常安全确认，不会
被隐藏。0.2.9 起，新增目标默认自动准备 SSH 密钥并静默预检；只有 Linux 尚未接受
该公钥时，程序才会打开单独的 PowerShell 控制台用于输入一次性 Linux 密码。密码
不会传给界面或保存。

当前默认入口使用 React/Vite 仪表盘：界面由本机 Edge 应用窗口显示，PowerShell
桥接只监听 `127.0.0.1`，不会把管理 API 暴露到局域网。React 构建产物缺失时，在
仓库的 `web` 目录执行 `npm install` 和 `npm run build`；也可以使用
`Open-ProxyManager-React.cmd` 明确启动 React 入口。
React 仪表盘支持中英文切换。点击右上角的 `EN / 中` 即可切换，选择会保存在本机
浏览器中，下次打开时继续使用上次的语言；如果还没有选择，会跟随浏览器的中文语言设置，
否则默认使用英文。

侧边栏的“总览”“目标主机”和“活动记录”是三个独立页面：总览展示运行摘要，目标主机
管理目标列表与详情，活动记录展示完整操作日志。页面切换不会通过自动下拉定位。

0.2.4 起，隧道计划任务也通过真正无窗口的启动器运行，点击 Enable proxy 不会创建
或闪现 SSH 黑色控制台窗口。
0.2.8 起，同一个 Windows 会话只允许打开一个管理界面；重复启动会提示已有实例，
避免两个窗口同时操作同一份配置。

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
  - `CHECKING`：界面正在后台验证启用后的代理，或禁用后的远端端口关闭状态。
  - `RECOVERING`：单一隐藏协调进程正在顺序修复需要恢复的计划任务，不会锁住其他按钮。
  - `FAIL`：目标处于允许状态，但代理检测失败。
  - `DISABLED`：快速刷新确认目标配置为禁用；尚未做远端检查。
  - `BLOCKED`：深度检查确认远端代理端口已经关闭。
  - `LEAK`：目标配置为禁止，但远端端口仍然开放，需要立即排查其他隧道。
  - `UNKNOWN`：Linux 离线或 SSH 不可达，无法远端确认。

灰色行表示长期禁止。淡红色行表示目标允许，但任务未运行。红色行表示检测到
`LEAK`。

界面打开时会先识别配置为允许、但任务处于 `Ready` 或 `Disabled` 的目标，再启动一个
隐藏协调进程。协调进程最多等待本机代理 30 秒，并按配置顺序逐台恢复目标；完成后界面
再执行端到端验证，因此窗口不会被恢复命令锁住，也不会为每台机器启动一个恢复进程。
任务为 `Missing` 时不会盲目启动，而会显示 `Update required`，需要执行 Edit / Update
重建。登录任务固定延迟 15 秒启动；SSH 意外退出后，无窗口启动器每 5 秒重试，避免
开机网络尚未就绪时永久停止。

## 按钮说明

### Add target

添加并安装一台 Linux。它会上传 Linux 端文件、创建独立计划任务、启动隧道并
验证代理。每个新目标都会生成自己的目标 ID，并在 Windows 管理目录下创建独立的
无密码 Ed25519 密钥；免密预检成功时不弹任何控制台，只有新 Linux 尚未接受公钥时
才打开控制台，密码只在其中输入一次且不会保存。

### Edit / Update

修改目标参数并重新部署 Linux 文件和 Windows 计划任务。更新期间该目标会短暂
断线，其他目标不受影响。修改计划任务名时，旧任务会先被停止并注销；如果新任务名
已被其他任务占用，更新会直接拒绝而不会覆盖。启动、验证或配置保存失败时，新隧道会
自动关闭并注销；再次执行 Update 可重建，且不会出现界面未记录但登录后仍会自启的代理。

### Enable proxy / Restart proxy / Disable proxy

主界面的动态按钮和表格最左侧 `Enabled` 复选框执行相同操作。可直接点击，无需确认
弹窗；操作成功后也不会再弹成功提示，只有同步启动失败时才会弹出错误信息：

- 当前为禁止状态时显示 `Enable proxy`：长期允许所选 Linux 使用代理，立即启动
  隧道；确认本机 Clash、计划任务和受管 SSH 进程已启动后立即返回。随后该行显示
  `CHECKING`，界面通过隐藏的后台进程只验证所选目标；完成后变为 `OK` 或 `FAIL`。
  后台验证期间其他按钮和目标仍可操作。Windows 下次登录时计划任务会自动启动。
- 当前配置为允许但任务处于 `Ready` 或 `Disabled` 时显示 `Restart proxy`：不改变
  授权状态，通过隐藏后台进程恢复隧道并验证代理。
- 计划任务为 `Missing` 时显示 `Update required` 且不会尝试启动；使用
  Edit / Update 重建任务。
- 当前为允许状态时显示 `Disable proxy`：长期禁止所选 Linux 使用这台 Windows
  的 Clash 代理。它会：

1. 停止并禁用该目标的计划任务；
2. 清理与该目标匹配的残留 SSH 反向隧道进程；
3. 保存禁止状态并立即恢复界面操作；
4. 由隐藏的后台进程确认 Linux 远端代理端口已经关闭。

同步阶段只等待本机计划任务和匹配的 SSH 进程确实关闭，因此操作不再受 Linux 网络
延迟影响。随后该行显示 `CHECKING`，完成后变为 `BLOCKED`、`LEAK` 或 `UNKNOWN`。
`BLOCKED` 表示远端端口已确认关闭；`LEAK` 会用红色提示。需要刷新所有目标的最新
SSH/代理状态时，仍可手动点击 Health check。
`Disable proxy` 不是 Linux 防火墙：如果 Linux 本身具有无需此代理的直连网络，
它仍然可以直接联网。

`Disable proxy` 不会卸载 Linux 文件。Linux 已打开的终端中仍可能保留
`HTTP_PROXY` 等环境变量，但这些变量指向的端口已不可用，所以联网命令会失败。
需要临时直连时，在 Linux 当前终端运行 `proxy_off`。

### Advanced SSH settings

低频维护操作集中在这里：

- 添加/编辑目标时，普通表单不会要求选择私钥。展开 `Advanced SSH settings` 才能
  指定外部私钥路径；留空则使用该目标 ID 对应的专属 Ed25519 密钥。不同目标不能
  共享同一个私钥路径。
- `Configure SSH login`：准备该目标的专属/指定 Windows SSH 密钥，并检查所选 Linux
  账号是否已接受公钥。已经可免密登录时不会打开控制台；否则只打开一次 PowerShell
  控制台要求输入 Linux 密码。不会复制或保存私钥、密码。
- `Refresh local status`：只读取 Windows 本地配置、Clash 端口和计划任务状态，
  不连接 Linux，速度较快。
- `Remove target`：先显示确认框。确认后删除 Windows 计划任务、Linux 代理 Shell
  集成和该目标对应的 `authorized_keys` 公钥；对程序生成的专属私钥，确认框默认
  勾选同时删除本机私钥和 `.pub` 文件。手工指定的外部私钥不会被自动删除。Linux
  账号本身不会删除；远端清理失败时会保留目标配置，方便重试。

### Health check

连接每台 Linux，实际检查 SSH、代理可用性或禁止状态。不可达主机可能等待数秒。
这是手动的全量端到端检查；`BLOCKED` 表示禁用状态已从远端得到确认。0.2.8 起，
每个目标由独立隐藏进程并行检查，表格逐行显示 `CHECKING`，其他按钮和目标仍可操作。
检查期间按钮显示 `Cancel checks`，再次点击会取消全部手动检查并终止相应的后台
PowerShell/SSH 进程。

同一目标开始新的 Health check、Enable 或 Disable 时，旧检查会被自动取消，避免旧
结果或旧进程继续占用时间。日志会记录每个目标的完成耗时。

## 常见问题

### 为什么没有 Start / Stop

它们会制造“允许但没有运行”等中间状态，容易与 Enable/Disable 混淆。0.2.3 起，
界面和公开命令行只提供 `enable` 与 `disable`；内部启停计划任务仍由程序自动完成。

### 为什么 Open-ProxyManager.cmd 会出现窗口

`.cmd` 文件必须先由 Windows 的 CMD 主机执行，所以无法保证绝对零闪烁。0.2.7 起，
它只做一次快速转交并立即退出，不会再保留 PowerShell 窗口。希望完全无黑框时，请
直接双击 `Open-ProxyManager.vbs`。界面需要提权时仍会显示 UAC 权限提示，这是预期
行为；只有自动预检确认 Linux 尚未接受 SSH 公钥，或主动执行 `Configure SSH login`
且确实需要安装时，才会另外打开可交互控制台。

### Enable / Disable 为什么以前较慢

早期版本在命令已经验证结果后，界面还会重复执行完整 Health check。0.2.4 已取消重复检查，
并合并禁用状态的 SSH 与端口探测。0.2.6 起，Enable 的端到端代理检查转入隐藏后台，
0.2.7 起，Disable 的远端端口确认也转入隐藏后台。按钮只等待本机任务与受管 SSH
进程完成启停。0.2.8 起，手动 Health check 会并行检查所有目标且不锁住界面；启用
目标的 SSH 可达性和代理联网共用一次 SSH 会话。需要所有目标的最新全量状态时仍可
点击 Health check，运行中可再次点击取消。

### 为什么开启后目标行以前会消失一下再出现

早期版本的刷新实现会先清空整张表，再重新添加所有目标。0.2.6 改为保留现有行并原地更新，
同时启用表格双缓冲；目标行、勾选框和当前选择不会再在 Enable 后短暂消失。

### Disable proxy 后 Linux 命令无法联网

这是预期行为：Linux 终端仍在尝试连接已被关闭的代理端口。运行 `proxy_off` 可在
当前终端临时改为直连；再次点击 Enable proxy 后，新旧终端都可以继续通过代理。

### Proxy 显示 FAIL

确认 Windows Clash 正在运行且顶部显示 `[UP]`，然后点击 Enable proxy，再运行
Health check。也要确认 Windows 能通过 SSH 公钥登录目标 Linux。日志中的 `Reason`
会区分 `task-stopped`、`task-disabled`、`task-missing`、`ssh-unreachable` 和
`remote-proxy-unavailable`，可先按该原因定位，不必只看笼统的 FAIL。

0.2.5 起，健康检查会依次尝试 Gstatic、Cloudflare 和 Google，单个站点故障不会再把
整个代理误报为 FAIL。健康检查为 OK 只表示代理链路可用，不保证每一个网站都可访问；
如果只有 Google 等特定网站失败，请在 Clash 中检查当前节点和分流规则。

### Proxy 显示 LEAK

说明禁止状态与远端实际端口不一致。先检查是否存在其他手工建立的反向隧道或其他
Windows 控制端。重新启用后再点击 Disable proxy，会再次清理本机匹配的受管隧道。

### 日志出现乱码或颜色控制字符

重新打开 `Open-ProxyManager.vbs` 重新打开。0.2.2 起，启动器、Windows
PowerShell 和 SSH/SCP 输出统一使用 UTF-8，日志框也会移除 ANSI 颜色控制字符。
0.2.9 起，配置文件也在 Windows PowerShell 5.1 下显式按 UTF-8 读取，中文任务名不再
依赖系统 ANSI 代码页。

### 同时打开多个窗口或命令会怎样

管理界面按 Windows 会话实行单实例。CLI 或 UI 修改配置时，还会按配置文件路径持有
跨进程互斥锁，覆盖完整的读取、任务/远端操作和保存过程。另一个修改命令会等待前一
个完成，超过等待时间则明确报错，不会拿旧配置覆盖新结果。只读的本地刷新和状态检查
不持有写锁。

## 控制边界

本工具按 Linux 主机允许或禁止，不按网站、URL、Linux 进程分别授权。远端端口只
监听 Linux 的 `127.0.0.1`，不会暴露给局域网中的其他机器；但同一 Linux 上知道
端口的其他本地账号仍可能主动连接，严格的多账号隔离需要额外的 Linux 防火墙或
账号隔离策略。它也不会阻止 Linux 使用自身的直连网络。
