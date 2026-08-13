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
│   │   ├── SshBootstrap.ps1   # 本机密钥准备、免密预检与公钥安装
│   │   ├── Tunnel.ps1         # Windows 计划任务与 SSH 隧道生命周期
│   │   ├── Remote.ps1         # Linux 安装、卸载与代理验证
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
- `Config` 与 `Transport` 是 CLI 基础层；`src/manager/SshBootstrap.ps1`、`Tunnel` 和
  `src/manager/Remote.ps1` 在其上分别处理密钥、Windows 隧道和 Linux 状态；
  `Operations` 负责组合用例。
- UI 不直接调用 manager 内部函数。普通操作通过稳定的 `proxy-manager.ps1` 入口启动，
  因此 CLI 与 UI 可以分别测试。
- `src/ui/Health.ps1` 拥有后台进程、取消、代次与缓存；对话框中不能再实现另一套健康检查。
- 密码只能存在于明确打开的交互式 SSH 控制台，不能进入参数对象、日志或配置文件。

## SSH 一键引导边界

1. SSH 密钥存在性、公钥派生、免密预检和公钥安装只放在
   `src/manager/SshBootstrap.ps1`。
2. `proxy-manager.ps1` 的 `prepare-ssh` 只编排静默准备和预检，`bootstrap-key` 承担必要的
   一次性交互安装；入口不包含密钥处理细节。
3. 新增目标默认启用自动 SSH 配置，选项位于 `src/ui/Dialogs.ps1`；是否启动交互式控制台
   由 `src/ui/Runtime.ps1` 根据预检结果决定。
4. 已能免密登录时不创建控制台；只有远端尚未接受公钥时，才要求用户输入一次 Linux
   密码。密码不会进入参数对象、日志或配置。
5. 缺失密钥、已有密钥、首次交互和失败清理路径由 `tests/Test-Manager.ps1` 与
   `tests/UiSmoke.ps1` 覆盖，并继续接受敏感信息扫描。

这套边界的目标不是追求文件数量，而是让配置、Windows 隧道、Linux 操作和界面状态
能够独立修改与验证。
