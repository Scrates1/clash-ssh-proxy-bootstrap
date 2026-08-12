# 代码结构

仓库根目录只保留用户直接调用的稳定入口。实现代码位于 `src`，测试代码位于
`tests`。私人目标配置仍只保存在 `%LOCALAPPDATA%\ClashSshProxy\config.json`，不会
进入仓库。

```text
clash-ssh-proxy-bootstrap/
├── proxy-manager.ps1          # CLI 参数与命令事务编排
├── proxy-manager-ui.ps1       # UI 启动、控件布局与事件连接
├── src/
│   ├── Common.ps1             # CLI/UI 共用的路径与进程参数工具
│   ├── manager/
│   │   ├── Config.ps1         # 配置、校验、目标默认值与跨进程写锁
│   │   ├── Transport.ps1      # OpenSSH 参数、远端命令与通用探测
│   │   ├── Tunnel.ps1         # Windows 计划任务与 SSH 隧道生命周期
│   │   ├── Remote.ps1         # Linux 安装、代理验证与 SSH 公钥引导
│   │   └── Operations.ps1     # 安装目标、状态查询与 CLI 帮助
│   └── ui/
│       ├── Bootstrap.ps1      # 提权前检查与 UI 单实例锁
│       ├── Runtime.ps1        # 配置读取、命令调用、日志与选择状态
│       ├── Health.ps1         # 并行、可取消的后台健康检查
│       └── Dialogs.ps1        # 帮助和目标编辑对话框
└── tests/
    ├── Test-Manager.ps1       # Windows PowerShell 5.1 集成回归
    └── UiSmoke.ps1            # 在 UI 脚本作用域内执行的界面烟雾测试
```

## 依赖方向

- 两个根入口可以加载 `src/Common.ps1` 和各自模块，模块不能反向启动入口。
- `Config` 与 `Transport` 是 CLI 基础层；`Tunnel` 和 `Remote` 在其上处理 Windows
  与 Linux 状态；`Operations` 负责组合用例。
- UI 不直接调用 manager 内部函数。普通操作通过稳定的 `proxy-manager.ps1` 入口启动，
  因此 CLI 与 UI 可以分别测试。
- `src/ui/Health.ps1` 拥有后台进程、取消、代次与缓存；对话框中不能再实现另一套健康检查。
- 密码只能存在于明确打开的交互式 SSH 控制台，不能进入参数对象、日志或配置文件。

## 后续 SSH 一键引导放置位置

以后实现“新增 Linux 时自动配置 SSH”时，按以下边界扩展：

1. SSH 密钥存在性、公钥派生、免密预检和公钥安装放在 `src/manager/Remote.ps1`；如果该
   文件继续增长，再单独拆成 `src/manager/SshBootstrap.ps1`。
2. `proxy-manager.ps1` 只增加稳定命令或编排分支，不放密钥处理细节。
3. 新增目标的选项和提示放在 `src/ui/Dialogs.ps1`，交互式控制台仍由 `src/ui/Runtime.ps1`
   统一启动。
4. 已能免密登录时静默跳过密码窗口；只有预检失败时才进入交互式密码流程。
5. 每条路径都必须在 `tests/Test-Manager.ps1` 或 `tests/UiSmoke.ps1` 中覆盖，
   并继续通过敏感信息扫描。

这套边界的目标不是追求文件数量，而是让配置、Windows 隧道、Linux 操作和界面状态
能够独立修改与验证。
