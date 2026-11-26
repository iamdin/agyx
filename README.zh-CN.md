# agyx

[English](README.md) | 简体中文

在同一系统用户下并行使用多个 Google 账号运行官方 Antigravity CLI（`agy`，支持 macOS 与 Linux）。每个 profile 拥有独立的登录凭据与应用设置，同时保持**真实 `HOME`** 并共享对话记录、历史、`brain`、`skills` 和 MCP 配置；原生裸 `agy` 与系统钥匙串完全不受影响。

纯 POSIX `sh` 实现，零运行时依赖。

## 安装

先安装[官方 `agy`](https://antigravity.google/docs/cli/overview)（`>= 1.5.16`），再安装 `agyx`：

```sh
curl -fsSL https://antigravity.google/cli/install.sh | bash
curl -fsSL https://raw.githubusercontent.com/iamdin/agyx/main/scripts/install.sh | sh
```

安装脚本会把 `bin/` 与 `runtime/` 放到 `~/.local/lib/agyx`，并链接 `~/.local/bin/agyx`（若不在 `PATH` 里请自行加入；agyx 从不改 Shell 启动文件）。账号数据仍在 `~/.local/share/agyx`。
macOS 也可用 Homebrew：

```sh
brew tap iamdin/tap
brew trust iamdin/tap
brew install agyx
```

## 使用

```sh
agyx profile login work            # 创建 profile 并登录（首个登录自动设为默认）
agyx profile login personal
agyx profile default work          # 查看或切换默认 profile
agyx profile list                  # 查看所有 profile 及其登录账号
agyx profile usage                 # 查看默认 profile 的用量额度
agyx profile usage personal        # 查看指定 profile 的用量额度
agyx profile usage --all --json    # 并行查询所有 profile 的额度，输出 JSON
agyx profile current               # 查看启动时会用哪个 profile
agyx profile remove personal       # 将指定 profile 移入废纸篓（别名：rm）

agyx                               # 启动默认 profile
agyx --profile personal -p "hi"    # 指定 profile 运行
agyx --profile personal -c         # 换另一个账号无缝续接最近一次对话
agyx --profile personal -r <id>    # 换另一个账号续接指定 ID 的对话
AGYX_PROFILE=work agyx models      # 通过环境变量指定 profile

agyx doctor                        # 检查安装状态、目录权限与软链
agyx uninstall                     # 将数据移入废纸篓并卸载 agyx
```

选择优先级：前置 `--profile NAME` > `AGYX_PROFILE` > 默认 profile。名称需匹配 `[a-z][a-z0-9_-]{0,31}`（`profile`、`doctor`、`uninstall` 为保留字），其余参数原样透传给 `agy`。`agyx profile usage` 跑的是 agy 的 `/usage`。

### Agentic IDE 与多路复用器（Herdr、Zed、JetBrains、T3 Code）

将工具的 `agy` 可执行路径设为 `~/.local/share/agyx/agy`（升级后仍保持稳定的 shim 入口）。可通过环境变量 `AGYX_PROFILE=work` 或在 `agy` / `agy acp` 参数前加 `--profile work` 指定账号；未指定时使用默认 profile。

### 给 AI agent 和脚本用

- `profile list | current | default | usage | remove` 和 `doctor` 支持 `--json`，stdout 只输出一个 JSON；失败时输出 `{"ok":false,"error":{"code","message","hint"}}`。不加 `--json` 时 stdout 只放数据，提示一律走 stderr。
- 退出码：`0` 成功，`1` 出错（或 `doctor` 发现问题），`2` 用法错误，`3` 未初始化 / 没有或不存在该 profile，`4` 未登录，`5` 需要人来操作（终端或浏览器登录）。
- 没有终端时绝不等待输入：需要确认的操作直接以 `5` 退出，除非加 `--yes`（或 `AGYX_ASSUME_YES=1`）。`agyx profile login` 始终需要人来完成。
- `agyx profile usage --all --json` 并行查询所有已登录 profile（约 10 秒）：`[{"profile","ok","limits":[{"group","window":"5h|weekly","remaining","resets_at"}]}]`。
- 每个子命令都有 `--help`，写明 JSON 结构和退出码，例如 `agyx profile usage --help`。

## 工作原理与路径

- **数据目录（`${AGYX_DATA_DIR:-~/.local/share/agyx}`）**：首次写入前询问一次确认（脚本可设 `AGYX_ASSUME_YES=1` 跳过），仅存放 `agy` 入口链接、`default` 和 `profiles/<name>/`。
- **共享与私有边界**：对话、`history.jsonl`、`conversation_summaries.db`、`brain`、`skills`、`mcp` 等软链至 `~/.gemini/antigravity-cli/` 跨账号共享；Token、`settings.json`、`cache/`、`daemon/`、`persistent_terminals/` 及原生 `log/` 按账号私有隔离。若共享项发生冲突（`DRIFT`），下次启动会询问确认后自动合并，被替换副本移入系统废纸篓。
- **全平台零侵入隔离**：直接通过 `exec` 加 `--app_data_dir` 与 `AGY_CLI_FORCE_FILE_TOKEN_STORAGE=1` 启动原生 `agy`，在 macOS、Linux、桌面、SSH 以及 `agy acp` 下行为完全一致，完全不碰系统钥匙串，也不修改 `ZDOTDIR` / `BASH_ENV` 等 Shell 启动变量。

全程不修改任何 Shell 配置文件、`PATH` 或系统登录钥匙串。原生 `agy` 每次从 `PATH` 或 `~/.local/bin/agy` 动态查找（可用 `AGYX_REAL_AGY=/path/to/agy` 覆盖）。

## 安全性

登录凭据以 `0600` 权限文件保存在 `0700` 的各账号目录内——与 `agy` 在 Linux 和 SSH 下的原生存储格式完全一致；在开启磁盘加密（如 macOS FileVault）的设备上，日常安全性与系统钥匙串相当（类似 `~/.ssh` 私钥）。使用者需注意：当前系统用户下的任何进程均可直接读取该文件，请勿同步 `~/.local/share/agyx` 或将其放入未加密备份，执行 `agyx uninstall` 后请清空废纸篓以彻底销毁旧凭据。

## 开发与测试

```sh
sh test/run.sh
sh test/release.sh
shellcheck -s sh -S warning bin/agy bin/agyx runtime/sync.sh test/run.sh test/release.sh scripts/release.sh scripts/install.sh
```

## 许可证

MIT，详见 [LICENSE](LICENSE)。
