# DSCodex Windows Maintenance

[English](README.en.md)

在 Windows 上为 [DSCodex](https://github.com/fish2lab/DSCodex) 补齐路由器守护、GPT 模型目录自动刷新和命令行入口跟随更新。

DSCodex 提供 GPT / DeepSeek 在原版 Codex / ChatGPT 桌面应用模型选择器中共存和按模型分流。本仓库发布配套维护脚本，不包含路由器，也不修改桌面应用。

## 为什么需要它

使用 `model_catalog_json` 后，Codex 从自定义静态目录加载模型；原来的 `models_cache.json` 不会由这个静态目录管理器自动刷新。DSCodex 的 `sync` 会重新合并本地缓存，但旧缓存没有新 GPT 模型时，反复 `sync` 也无法发现它们。

本方案在临时 `CODEX_HOME` 中调用应用自带 CLI，让它走原生目录发现流程，再把新缓存交给 DSCodex 合并。

| 文件 | 机制 | 作用 |
| --- | --- | --- |
| `scripts/dscodex-watchdog.ps1` | 每约 20 秒检查路由端口，关闭时拉起；每约 10 分钟启动目录检查 | 保持路由可用，自动触发维护 |
| `scripts/refresh-models.ps1` | 首次、CLI 路径变化或成功刷新已满 14 天时抓取目录；失败后至少等待 30 分钟再尝试 | 更新 GPT 缓存，再运行 DSCodex `sync` |
| `scripts/codex.cmd` | 每次调用从 `config.toml` 读取 `CODEX_CLI_PATH` | 跟随应用写入的新 CLI 路径 |

**约 10 分钟是检查周期，不是所有新模型发布后的可见时间保证。** 如果服务器发布模型但 CLI 路径没有变化，脚本会等到 14 天条件满足；也可以用 `-Force` 立即刷新。网络错误和失败退避会延长时间。刷新成功后仍需完全退出并重新打开应用。

## 前提

- Windows，Windows PowerShell 5.1 或更新版本；看门狗使用 CIM/WMI 创建后台进程。
- DSCodex 已按上游 README 安装，GPT 和 DeepSeek 均已能正常使用。
- 能运行 DSCodex 的 Node.js 版本（原始部署使用 Node.js 24）；无需为本仓库安装 npm 依赖。
- 默认用户目录 `~/.codex` 中已有 ChatGPT 登录文件 `auth.json`。
- `~/.codex/config.toml` 中存在应用维护的 `CODEX_CLI_PATH`，且指向可执行的原生 Codex CLI。
- 能访问 ChatGPT 模型目录服务；脚本优先读取 DSCodex 的代理设置，再尝试 Windows 用户代理设置，未找到时沿用进程网络环境。

脚本面向默认 `~/.codex`；自定义 Codex 主目录不在本版本支持范围内。不要把 `CODEX_CLI_PATH` 改成这里的 `codex.cmd`，它只是终端入口，不能替代 Windows 桌面端需要的原生 `.exe`。

## 1. 安装 DSCodex

先按 [DSCodex 官方 README](https://github.com/fish2lab/DSCodex#readme) 完成安装、设置 DeepSeek key、必要的代理配置及 `doctor` 检查。

第一次安装后完全退出应用（含托盘）再打开，在新任务中确认 DeepSeek 和 GPT 都可以使用，然后继续下面步骤。当前模型名称和路由能力以 DSCodex 上游版本为准。

## 2. 获取维护脚本

```powershell
git clone https://github.com/wangchenwj/dscodex-windows-maintenance.git
cd dscodex-windows-maintenance

# 改为你的实际路径；路径中可以有空格。
$repoPath = (Get-Location).Path
$dsPath = 'D:\tools\DSCodex'
$nodePath = 'D:\tools\node24\node.exe'
```

如果符合版本要求的 Node 已在 PATH 中，`$nodePath` 可以写为 `(Get-Command node.exe).Source`。登录启动时也需要能找到该文件，建议使用绝对路径。

## 3. 先手动刷新目录

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$repoPath\scripts\refresh-models.ps1" -DscodexPath $dsPath -NodePath $nodePath -Force
```

刷新时使用故意不存在的模型 `dscodex-refresh-probe`，预期该模型请求会失败；成功与否取决于是否取得可解析的模型缓存并成功 `sync`，不取决于 CLI 推理请求的退出码。原始部署观察到目录能正常取得，且不会产生成功的 GPT 推理；这里不承诺未来服务端的额度计量方式。

查看 `~/.codex/dscodex/refresh.log`，出现 `refreshed: ... catalog synced` 后完全重启应用查看模型选择器。原缓存的单份备份是 `~/.codex/models_cache.json.pre-refresh.bak`。

## 4. 启用看门狗和登录自启

先在一个 PowerShell 窗口中运行，确认它能保持路由器运行；按 Ctrl+C 结束这次手动运行，再注册登录启动。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$repoPath\scripts\dscodex-watchdog.ps1" -DscodexPath $dsPath -NodePath $nodePath

# 注册当前用户登录自启，无需管理员权限。
$watchdog = Join-Path $repoPath 'scripts\dscodex-watchdog.ps1'
$startupCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $watchdog + '" -DscodexPath "' + $dsPath + '" -NodePath "' + $nodePath + '"'
Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'DSCodexWindowsMaintenance' -Value $startupCommand

# 当前登录立即启动一次（注册表项从下次登录开始生效）。
Start-Process powershell.exe -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $watchdog + '" -DscodexPath "' + $dsPath + '" -NodePath "' + $nodePath + '"') -WindowStyle Hidden
```

路径应使用绝对路径，目录参数不要以反斜杠结尾。保持这个仓库和 DSCodex 的路径稳定。只运行一个看门狗实例，也不要并行手动刷新；如果已有旧看门狗或其他自启方案，先停止重复实例并移除对应启动项。

默认端口 `10110`。如果 DSCodex 使用其他端口，在启动命令后加 `-Port 你的端口`。检查只判断 TCP 端口是否接受连接，不验证端口后面的服务身份或完整功能。

## 5. 可选：安装命令行 shim

`codex.cmd` 是给终端使用的轻量入口。它读取 `config.toml` 中**以单引号写入的** `CODEX_CLI_PATH`（原始部署所用格式），不支持多行值或双引号值。刷新脚本支持常见的单引号值以及双引号 Windows 路径。

```powershell
$binPath = Join-Path $env:USERPROFILE '.codex\bin'
New-Item -ItemType Directory -Path $binPath -Force | Out-Null
# 先确认目标目录没有你需要保留的同名 codex.cmd。
Copy-Item -LiteralPath "$repoPath\scripts\codex.cmd" -Destination $binPath
```

通过 Windows“编辑账户的环境变量”把 `%USERPROFILE%\.codex\bin` 加入用户 PATH，再打开新终端。若已有其他 `codex`，用 `Get-Command codex -All` 检查实际使用的入口顺序。

shim 依赖应用确实更新配置中的路径；它不会自行寻找二进制，也不会启动路由器。

## 日志和故障定位

文件位于 `~/.codex/dscodex/`：

- `watchdog.log`：路由拉起、心跳和刷新进程启动结果。
- `refresh.log`：目录刷新结果。
- `refresh-exec.log` / `refresh-exec.log.err`：目录获取时的 CLI 输出。
- `refresh-sync.log`：DSCodex `sync` 输出。
- `refresh-marker.json`：上次路径、成功时间和尝试时间，仅用于刷新节流，不恢复会话。

找不到 `CODEX_CLI_PATH` 时不会自动推断路径，先检查应用配置。网络故障时查看获取日志；`sync` 失败查看合并日志。`-Force` 会绕过时间条件和失败退避。

临时目录会复制 ChatGPT 登录凭据，限制为当前用户访问，并在正常结束或捕获到错误后删除。进程被强制终止、关机或断电可能留下 `%TEMP%\dscodex-refresh-*`；确认没有刷新进程运行后可手动删除。不要发布运行日志、缓存、状态文件、`auth.json` 或 DSCodex 的私有配置。

## 停用

```powershell
Remove-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'DSCodexWindowsMaintenance' -ErrorAction SilentlyContinue
```

这只移除本仓库的登录启动项。若当前看门狗仍在运行，在任务管理器中根据命令行定位并结束该脚本对应的 PowerShell 进程。可选 shim 不再需要时移除你安装的 `.codex\bin\codex.cmd` 和相应 PATH 项。

卸载 DSCodex 使用上游卸载命令；停止看门狗后再卸载，否则它会尝试重新启动路由器。

## 验证范围与来源

原始个人部署在 Windows 11、桌面应用 26.903.8094.0、Node.js 24.19.0 和 DSCodex 本地版本上使用。这一公开版本将路径改为参数，并增加独立临时目录及凭据访问限制；已做静态语法和发布内容检查，未在干净 Windows 环境做完整安装及升级验证。目录发现依赖当前 CLI 的行为，未来版本可能需要适配。

GPT / DeepSeek 共存能力归功于 [fish2lab/DSCodex](https://github.com/fish2lab/DSCodex)。本仓库整理 Windows 配套维护流程。

参考：[Codex 配置文档](https://developers.openai.com/codex/config-reference/)、[DSCodex 目录合并源码](https://github.com/fish2lab/DSCodex/blob/main/src/catalog.mjs)。

## License

本仓库脚本与文档采用 [MIT](LICENSE) 许可证。DSCodex 是独立项目，采用其上游 MIT 许可证；本仓库不重新分发其路由器源码。
