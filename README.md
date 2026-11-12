# agyx

Run several official `agy` CLI (Google Antigravity CLI, macOS) instances at the same time under one macOS user, each logged in to a different Google account.

Each profile gets its own `HOME` (agy keeps its OAuth token under `$HOME/.gemini/antigravity-cli/`). `agyx` runs a shim (which can optionally also take over the name `agy`) that picks the profile and starts the real agy with that `HOME`. A shell bridge restores the real `HOME` in shells the agent spawns, so its Bash tool sees your normal environment.

POSIX `sh`, no dependencies.

(Previously called agyctl.)

## Install

With Homebrew:

```sh
brew install iamdin/tap/agyx
agyx setup
```

`agyx setup` only records the official agy (first `agy` on `PATH`, or the path you pass) under the data dir. `agyx` is the only command you run; Homebrew puts it on `PATH`. agyx never edits your shell config.

Then log in once per account:

```sh
agyx login work        # runs agy's native login in profile "work"
agyx login personal
agyx use work          # default profile
agyx doctor            # checks that `agyx` on PATH is this script
```

### Optional: take over the bare `agy` name

By default the official `agy` is left alone. `agyx shim` creates `<data dir>/bin/agy` (a link to the shim) and tells you that `<data dir>/bin` must now come **before** the real agy's directory in `PATH` (the official installer uses `~/.local/bin`, so put `export PATH="$HOME/.local/share/agyx/bin:$PATH"` at the end of your shell config). `agyx unshim` removes only that link (it refuses to remove anything that is not a symlink to the shim). Both are idempotent.

Inside an agent's shell, a nested `agyx` always routes to the inherited profile. A nested bare `agy` does only with the takeover on; without it, it runs the real agy with the real `HOME`, i.e. the default account, not the instance profile. `agyx doctor` reports which mode you are in.

From a git clone instead of Homebrew:

```sh
git clone https://github.com/iamdin/agyx && cd agyx
./bin/agyx setup       # then link bin/agyx onto PATH, e.g. ln -s "$PWD/bin/agyx" ~/.local/bin/agyx
```

Keep `bin/` and `runtime/` together; the scripts locate each other by resolving their own real path (symlinks are fine).

## Use

Profile choice: leading `--account NAME` > `AGY_PROFILE` > default (`agyx use`).

`agyx` launches agy unless its first argument is one of its own management subcommands: `setup`, `login`, `use`, `list`, `doctor`, `shim`, `unshim`. None of them overlaps with a real agy subcommand (`acp`, `agent`, `agents`, `changelog`, `help`, `install`, `mcp`, `mic-serve`, `models`, `plugin`, `plugins`, `remote-control`, `update`) or flag (`-h`, `--help`), so all of those, and `agyx --help`, reach the real agy:

```sh
agyx                          # default profile
agyx --account personal -p "hello"
AGY_PROFILE=work agyx --model x
agyx --account work mcp list
agyx --help                  # agy's own help
agyx install                  # agy's own `install` subcommand
```

(After `agyx shim`, the same works with the bare `agy`.) The seven management subcommand names are reserved and rejected as profile names.

### agyx usage

```
usage: agyx setup [path]      record the official agy (default: first agy in PATH)
       agyx login NAME        create profile NAME and log in with agy's native login
       agyx use NAME          set the default profile
       agyx list              list profiles
       agyx doctor            check the installation
       agyx shim | unshim     enable / disable the optional bare 'agy' takeover
       agyx [--account NAME] [agy args...]   anything else launches agy
```

This usage is printed (exit 2) on any misuse of a management subcommand: a missing, extra, invalid or reserved argument, or an unknown profile.

`--account` is only read before any other argument (`--` ends it); everything after is passed to agy untouched. A bad or missing profile is an error, never a fallback to another one.

`agyx list` shows profiles and whether the token file exists ("token file present", not proof of a valid login).

Data dir: `${AGYX_DATA_DIR:-~/.local/share/agyx}` holding `real-agy`, `bin/agy` (only after `agyx shim`), `default`, `profiles/<name>/home/`.

## Tests

```sh
sh test/run.sh      # uses a fake agy; never runs the real one
```

## Known limits

- Not a security boundary (same UID).
- Only shells that read their startup files get the real `HOME`; programs agy runs directly, MCP servers, and agy's own file tools still see the profile `HOME`.
- Isolation relies on agy 1.5.6 falling back to per-`HOME` token files when the keychain is not reachable. Token refresh, logout, and agy upgrades are not yet verified.
- Each token save may wait about 5 seconds for the keychain timeout.
