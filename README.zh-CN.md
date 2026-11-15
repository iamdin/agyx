# agyx

[English](README.md) | 简体中文

在同一系统用户下并行使用多个 Google 账号运行官方 Antigravity CLI（`agy`，支持 macOS 与 Linux）。每个 profile 拥有独立的登录凭据与应用设置，同时保持**真实 `HOME`** 并共享对话记录、历史、`brain`、`skills` 和 MCP 配置；原生裸 `agy` 与系统钥匙串完全不受影响。

纯 POSIX `sh` 实现，零运行时依赖。

## 安装

先安装[官方 `agy`](https://antigravity.google/docs/cli/overview)，再安装 `agyx`：

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

agyx                               # 启动默认 profile
agyx --profile personal -p "hi"    # 指定 profile 运行
agyx --profile personal -c         # 换另一个账号无缝续接最近一次对话
AGYX_PROFILE=work agyx models      # 通过环境变量指定 profile

agyx setup t3code                  # 交互：把各 profile 写入 T3 Code
agyx setup t3code -y               # 非交互：直接写入（脚本用）
agyx doctor                        # 检查安装状态、目录权限与软链
agyx uninstall                     # 将数据移入废纸篓并卸载 agyx
```

选择优先级：前置 `--profile NAME` > `AGYX_PROFILE` > 默认 profile。名称需匹配 `[a-z][a-z0-9_-]{0,31}`（`profile`、`doctor`、`setup`、`uninstall` 为保留字），其余参数原样透传给 `agy`。

### 接入客户端与 IDE（如 T3 Code）

```sh
agyx setup t3code       # 终端里交互确认
agyx setup t3code -y    # 非交互（或 AGYX_ASSUME_YES=1）
```

要求已有 `~/.t3/userdata/settings.json`（先打开过一次 T3 Code）。校验通过后，把每个 profile 写成 Antigravity instance：`binaryPath` 指向 **`~/.local/share/agyx/agy`**（绝对路径），并设置 `AGYX_PROFILE=<name>`。改完后重启 T3 Code。

手动配置时同样指向该入口（须用绝对路径；不要写 `~`），并为每个实例设置环境变量 `AGYX_PROFILE=<name>`（不配则走默认 profile）。

## 工作原理与路径

- **数据目录（`${AGYX_DATA_DIR:-~/.local/share/agyx}`）**：首次写入前询问一次确认（脚本可设 `AGYX_ASSUME_YES=1` 跳过），仅存放 `agy` 入口链接、`default` 和 `profiles/<name>/`。
- **共享与私有边界**：对话、`history.jsonl`、`conversation_summaries.db`、`brain`、`skills`、`mcp` 等软链至 `~/.gemini/antigravity-cli/` 跨账号共享；Token、`settings.json`、`cache/` 及原生 `log/` 按账号私有隔离。若共享项发生冲突（`DRIFT`），下次启动会询问确认后自动合并，被替换副本移入系统废纸篓。
- **分平台零侵入隔离**：直接通过 `exec` 加 `--app_data_dir` 启动原生 `agy`。无头 Linux、容器及所有 SSH 会话直接使用原生文件存储（零额外环境变量）；带系统钥匙串的桌面会话（本地 macOS、Linux 桌面）注入 `WSL_INTEROP=agyx` 并在首层 Bash/Zsh 启动时自动清除还原。

全程不修改任何 Shell 配置文件、`PATH` 或系统登录钥匙串。原生 `agy` 每次从 `PATH` 或 `~/.local/bin/agy` 动态查找（可用 `AGYX_REAL_AGY=/path/to/agy` 覆盖）。

## 安全性

登录凭据以 `0600` 权限文件保存在 `0700` 的各账号目录内——与 `agy` 在 Linux 和 SSH 下的原生存储格式完全一致；在开启磁盘加密（如 macOS FileVault）的设备上，日常安全性与系统钥匙串相当（类似 `~/.ssh` 私钥）。使用者需注意：当前系统用户下的任何进程均可直接读取该文件，请勿同步 `~/.local/share/agyx` 或将其放入未加密备份，执行 `agyx uninstall` 后请清空废纸篓以彻底销毁旧凭据。

## 开发与测试

```sh
sh test/run.sh
sh test/release.sh
shellcheck -s sh -S warning bin/agy bin/agyx runtime/sync.sh runtime/bash_env runtime/zsh/.zshenv test/run.sh test/release.sh scripts/release.sh scripts/install.sh
```

## 许可证

MIT，详见 [LICENSE](LICENSE)。
