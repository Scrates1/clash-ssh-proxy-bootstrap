# 代码结构

仓库根目录只保留用户直接调用的稳定入口。实现代码位于 `src` 与 `web`，测试代码位于
`tests`。私人目标配置仍只保存在 `%LOCALAPPDATA%\ClashSshProxy\config.json`，不会
进入仓库。

```text
clash-ssh-proxy-bootstrap/
├── Open-ProxyManager.vbs          # React 默认启动器与 smoke-test 转发
├── Open-ProxyManager-React.vbs    # React 显式启动器
├── Open-ProxyManager.cmd          # VBS 兼容入口
├── Open-ProxyManager-React.cmd    # React 显式 CMD 入口
├── CONTRIBUTING.md                # 本地验证与发版约定
├── proxy-manager.ps1              # CLI 参数与命令事务编排
├── proxy-manager-react-host.ps1   # 回环 HTTP API、静态资源与 React 会话
├── web/
│   ├── src/                       # React/Vite 仪表盘与中英文资源
│   └── dist/                      # 已构建的前端资源
├── src/
│   ├── Common.ps1                # 路径、UTF-8 与 Windows 参数工具
│   ├── manager/
│   │   ├── Config.ps1            # 配置、目标 ID/密钥归属、唯一性校验与跨进程写锁
│   │   ├── Transport.ps1         # OpenSSH 参数、远端命令与通用探测
│   │   ├── SshBootstrap.ps1     # 本机密钥准备、免密预检、公钥安装与安全清理
│   │   ├── TunnelProcess.ps1    # 精确 SSH 命令签名与进程生命周期
│   │   ├── Tunnel.ps1            # Windows 计划任务与启动器生命周期
│   │   ├── Remote.ps1            # Linux 安装、卸载与代理验证
│   │   └── Operations.ps1        # 安装目标、状态查询与 CLI 帮助
│   └── ui/
│       ├── Bootstrap.ps1         # React 主机使用的提权检查与单实例锁
│       └── Http.ps1              # 请求来源/大小验证与浏览器安全响应头
└── tests/
    ├── Test-Manager.ps1          # Windows CLI/React 主机与启动器回归入口
    ├── Test-Hardening.ps1        # UTF-8、配置、任务迁移和失败注入
    ├── test-linux.sh             # Linux 安装/卸载与符号链接回归
    └── test-privacy.sh           # 跟踪文件敏感信息检查
```

前端统一验证入口是 `cd web; npm run check`，依次执行 ESLint、单元测试、TypeScript
检查和 Vite 生产构建。CI 随后检查 `web/dist`，防止提交的静态包与源码不一致。
`v<version>` 标签还会触发跨平台复测、版本一致性检查、ZIP 打包和 SHA-256 生成。

## 依赖方向

- CLI 与 React 主机加载 `src/Common.ps1` 和 `src/manager`；React 主机另外加载
  `src/ui/Bootstrap.ps1` 与 `src/ui/Http.ps1`，用于管理员检查、单实例锁和本地 HTTP
  安全边界。Smoke test 使用独立互斥锁，不会与正在使用的管理器实例竞争。
- React 前端位于 `web/src`，只通过 React 主机提供的回环 HTTP API 读取状态和提交操作；
  React 主机再调用稳定的 `proxy-manager.ps1` 入口，不直接调用 manager 内部函数。
- `Config` 与 `Transport` 是 manager 基础层；`SshBootstrap.ps1`、`TunnelProcess.ps1`、
  `Tunnel.ps1` 和 `Remote.ps1` 分别处理密钥、Windows 隧道和 Linux 状态；`Operations.ps1`
  负责组合安装、启用、禁用、恢复与状态查询用例，CLI 入口只做参数路由和事务锁定。
- React 主机负责本地状态快照、后台健康检查请求、交互式 SSH 控制台和静态资源服务；
  前端负责页面、向导、语言切换和活动记录展示。`use-manager-session.ts` 隔离实时状态、
  心跳与请求竞态，`manager-state.ts` 负责 PowerShell 返回值归一化和表单转换。
- React 会话令牌通过 URL fragment 交给前端，读取后立即从地址栏移除；API 同时校验
  会话令牌、同源来源和请求体大小，并为所有响应设置限制脚本、嵌入与引用来源的安全头。
  Smoke test 会发起真实的静态资源、鉴权与同源请求，验证监听器边界而非只检查源码；
  请求大小限制由独立的行为测试覆盖。
- 密码只能存在于明确打开的交互式 SSH 控制台，不能进入参数对象、日志或配置文件。
- 新目标使用稳定的 `tgt-...` ID；管理器为每个 ID 派生独立的 Ed25519 私钥路径。
  `host + user` 是目标唯一性，SSH 端口只是连接参数；目标之间不得共享私钥路径。

## 目标安装事务边界

1. `Operations.ps1` 在任何远端写入前完成管理员权限、本机工具、密钥、Clash、SSH 和
   新任务名冲突预检。
2. `Tunnel.ps1` 只允许覆盖配置中同一目标原有的任务；改名时先停止并注销旧任务，
   再注册新任务，不能用 `-Force` 覆盖无关任务。
3. 隧道进程由完整的 SSH 可执行文件、端口、密钥、反向转发、选项和目标参数共同识别，
   不能用主机名或端口子串误杀其他 SSH 会话。
4. 注册、启动、端到端验证或配置保存任一步失败，当前替换任务和启动器都会被停止并删除。
   第一次 `add` 还会撤销 Linux Shell 集成；更新失败则保留远端文件供重试，但不会
   保留活动的新隧道。
5. 配置只有在安装验证成功后才保存；`update-all` 任一目标失败时，已完成的本轮任务也
   会统一关闭，避免磁盘配置与部分活动任务长期分裂。
6. 删除目标时先清理 Windows 任务和远端 Linux 集成，再按确认选项删除管理器生成的
   本机私钥与 `.pub` 文件；外部私钥永不自动删除，远端公钥按精确 key type/data 移除。

Linux 安装器对启动文件先统一校验再写入。符号链接解析到普通文件后原子替换真实目标，
链接节点不变；悬空链接、目录或畸形托管标记会失败关闭。

## SSH 一键引导边界

1. SSH 密钥存在性、公钥派生、免密预检和公钥安装只放在
   `src/manager/SshBootstrap.ps1`。
2. `proxy-manager.ps1` 的 `prepare-ssh` 只编排静默准备和预检，`bootstrap-key` 承担必要的
   一次性交互安装；入口不包含密钥处理细节。
3. React 新增目标向导位于 `web/src/App.tsx`；React 主机根据预检结果决定是否启动
   `bootstrap-key` 的可交互 PowerShell 控制台。
4. 已能免密登录时不创建控制台；只有远端尚未接受公钥时，才要求用户输入一次 Linux
   密码。密码不会进入参数对象、日志或配置。
5. 缺失密钥、已有密钥、首次交互和失败清理由 `tests/Test-Manager.ps1`、
   `tests/Test-Hardening.ps1` 覆盖，并继续接受敏感信息扫描。

仓库级隐私回归位于 `tests/test-privacy.sh`，用于阻止敏感状态文件、私钥/令牌特征和
机器专属私网地址进入 Git 跟踪内容。

这套边界的目标不是追求文件数量，而是让配置、Windows 隧道、Linux 操作和 React 界面状态
能够独立修改与验证。
