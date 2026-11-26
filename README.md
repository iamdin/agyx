# agyx

English | [简体中文](README.zh-CN.md)

Run multiple Google accounts side by side with the official Antigravity CLI (`agy`, macOS & Linux). Each profile gets its own login and settings while keeping your **real `HOME`** and sharing conversations, history, brain, skills, and MCP config. Plain `agy` and your system keyring stay untouched.

POSIX `sh`, zero runtime dependencies.

## Install

Install [the official `agy`](https://antigravity.google/docs/cli/overview) (`>= 1.5.16`) first, then install `agyx`:

```sh
curl -fsSL https://antigravity.google/cli/install.sh | bash
curl -fsSL https://raw.githubusercontent.com/iamdin/agyx/main/scripts/install.sh | sh
```

The installer puts `bin/` + `runtime/` in `~/.local/lib/agyx` and links `~/.local/bin/agyx` (add that dir to `PATH` if needed; agyx never edits shell startup files). Profile data stays in `~/.local/share/agyx`.

macOS with Homebrew instead:

```sh
brew tap iamdin/tap
brew trust iamdin/tap
brew install agyx
```

## Usage

```sh
agyx profile login work            # create profile and sign in (first login becomes default)
agyx profile login personal
agyx profile default work          # show or set the default profile
agyx profile list                  # list profiles and accounts
agyx profile usage                 # quota for the default profile
agyx profile usage personal        # quota for one profile
agyx profile usage --all --json    # every profile's quota, in parallel, as JSON
agyx profile current               # which profile a launch would use
agyx profile remove personal       # move a profile to the Trash (alias: rm)

agyx                               # launch default profile
agyx --profile personal -p "hi"    # launch a specific profile
agyx --profile personal -c         # continue the latest conversation under another account
agyx --profile personal -r <id>    # resume a specific conversation under another account
AGYX_PROFILE=work agyx models      # select profile via environment variable

agyx doctor                        # check installation, permissions, and links
agyx uninstall                     # move agyx data to Trash and uninstall
```

Profile precedence: leading `--profile NAME` > `AGYX_PROFILE` > default. Profile names match `[a-z][a-z0-9_-]{0,31}` (`profile`, `doctor`, and `uninstall` are reserved). Any other arguments pass straight through to `agy`. `agyx profile usage` runs agy's `/usage`.

### Agentic IDEs & Multiplexers (Herdr, Zed, JetBrains, T3 Code)

Point the tool's `agy` binary path to `~/.local/share/agyx/agy` (the stable shim entry that survives upgrades). Select a profile by setting `AGYX_PROFILE=work` in the environment or passing leading `--profile work` before `agy` / `agy acp` arguments; without either, it uses the default profile.

### For AI agents and scripts

- `--json` on `profile list | current | default | usage | remove` and `doctor` prints one JSON document on stdout; on failure it prints `{"ok":false,"error":{"code","message","hint"}}`. Without `--json`, stdout carries only data and notes go to stderr.
- Exit codes: `0` ok, `1` error (or `doctor` found issues), `2` usage, `3` not set up / no or unknown profile, `4` not logged in, `5` needs a person (a terminal or browser sign-in).
- Nothing waits for input without a terminal: confirmations fail with `5` unless `--yes` (or `AGYX_ASSUME_YES=1`). `agyx profile login` always needs a person.
- `agyx profile usage --all --json` checks every logged-in profile in parallel (about 10 s): `[{"profile","ok","limits":[{"group","window":"5h|weekly","remaining","resets_at"}]}]`.
- Every subcommand has `--help` with its JSON shape and exit codes, e.g. `agyx profile usage --help`.

## How it works & paths

- **Data directory (`${AGYX_DATA_DIR:-~/.local/share/agyx}`):** asked once on first write (`AGYX_ASSUME_YES=1` skips prompts). Holds the `agy` app entry, `default`, and `profiles/<name>/`.
- **Shared vs. private:** conversations, `history.jsonl`, `conversation_summaries.db`, `brain`, `skills`, and `mcp` link to `~/.gemini/antigravity-cli/`. Tokens, `settings.json`, `cache/`, `daemon/`, `persistent_terminals/`, and native `log/` stay private per profile. If a shared entry drifts, the next launch asks once before merging and moving displaced copies to the OS Trash.
- **Isolation:** `agy` is `exec`d directly with `--app_data_dir` pointing at the profile directory and `AGY_CLI_FORCE_FILE_TOKEN_STORAGE=1` across all platforms (macOS, Linux, desktop, SSH, and `agy acp`), leaving OS keyrings and shell startup variables (`ZDOTDIR` / `BASH_ENV`) completely untouched.

No shell startup files, `PATH`, or system keychains are modified. Native `agy` is discovered from `PATH` or `~/.local/bin/agy` (`AGYX_REAL_AGY=/path/to/agy` overrides).

## Security

Logins are stored as `0600` token files inside `0700` profile directories — the same format `agy` uses natively on Linux and SSH, with practical security comparable to the login keychain on an encrypted disk (like `~/.ssh` keys). Any process running as your OS user can read them: do not sync `~/.local/share/agyx` or back it up unencrypted, and empty the Trash after `agyx uninstall`.

## Development

```sh
sh test/run.sh
sh test/release.sh
shellcheck -s sh -S warning bin/agy bin/agyx runtime/sync.sh test/run.sh test/release.sh scripts/release.sh scripts/install.sh
```

## License

MIT, see [LICENSE](LICENSE).
