# agyctl

Run several official `agy` CLI (Google Antigravity CLI, macOS) instances at the same time under one macOS user, each logged in to a different Google account.

Each profile gets its own `HOME` (agy keeps its OAuth token under `$HOME/.gemini/antigravity-cli/`). `agyctl` runs a shim (which can optionally also take over the name `agy`) that picks the profile and starts the real agy with that `HOME`. A shell bridge restores the real `HOME` in shells the agent spawns, so its Bash tool sees your normal environment.

POSIX `sh`, no dependencies.

## Install

With Homebrew:

```sh
brew install iamdin/tap/agyctl
agyctl install
```

`agyctl install` only records the official agy (first `agy` on `PATH`, or the path you pass) under the data dir. `agyctl` is the only command you run; Homebrew puts it on `PATH`. agyctl never edits your shell config.

Then log in once per account:

```sh
agyctl login work        # runs agy's native login in profile "work"
agyctl login personal
agyctl use work          # default profile
agyctl doctor            # checks that `agyctl` on PATH is this script
```

### Optional: take over the bare `agy` name

By default the official `agy` is left alone. `agyctl shim` creates `<data dir>/bin/agy` (a link to the shim) and tells you that `<data dir>/bin` must now come **before** the real agy's directory in `PATH` (the official installer uses `~/.local/bin`, so put `export PATH="$HOME/.local/share/agyctl/bin:$PATH"` at the end of your shell config). `agyctl unshim` removes only that link (it refuses to remove anything that is not a symlink to the shim). Both are idempotent.

Inside an agent's shell, a nested `agyctl` always routes to the inherited profile. A nested bare `agy` does only with the takeover on; without it, it runs the real agy with the real `HOME`, i.e. the default account, not the instance profile. `agyctl doctor` reports which mode you are in.

From a git clone instead of Homebrew:

```sh
git clone https://github.com/iamdin/agyctl && cd agyctl
./bin/agyctl install     # then link bin/agyctl onto PATH, e.g. ln -s "$PWD/bin/agyctl" ~/.local/bin/agyctl
```

Keep `bin/` and `runtime/` together; the scripts locate each other by resolving their own real path (symlinks are fine).

## Use

Profile choice: leading `--account NAME` > `AGY_PROFILE` > default (`agyctl use`).

`agyctl` launches agy unless its first argument is one of its own subcommands (`install`, `shim`, `unshim`, `login`, `use`, `list`, `doctor`, `help`) or `-h`/`--help`:

```sh
agyctl                          # default profile
agyctl --account personal -p "hello"
AGY_PROFILE=work agyctl --model x
agyctl --account work mcp list
agyctl -- install               # a leading -- always launches: runs agy's own `install` subcommand
```

(After `agyctl shim`, the same works with the bare `agy`.) Profile names equal to an agyctl subcommand are rejected.

`--account` is only read before any other argument (`--` ends it); everything after is passed to agy untouched. A bad or missing profile is an error, never a fallback to another one.

`agyctl list` shows profiles and whether the token file exists ("token file present", not proof of a valid login).

Data dir: `${AGYCTL_DATA_DIR:-~/.local/share/agyctl}` holding `real-agy`, `bin/agy` (only after `agyctl shim`), `default`, `profiles/<name>/home/`.

## Tests

```sh
sh test/run.sh      # uses a fake agy; never runs the real one
```

## Known limits

- Not a security boundary (same UID).
- Only shells that read their startup files get the real `HOME`; programs agy runs directly, MCP servers, and agy's own file tools still see the profile `HOME`.
- Isolation relies on agy 1.5.6 falling back to per-`HOME` token files when the keychain is not reachable. Token refresh, logout, and agy upgrades are not yet verified.
- Each token save may wait about 5 seconds for the keychain timeout.
