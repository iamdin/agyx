# agyctl

Run several official `agy` CLI (Google Antigravity CLI, macOS) instances at the same time under one macOS user, each logged in to a different Google account.

Each profile gets its own `HOME` (agy keeps its OAuth token under `$HOME/.gemini/antigravity-cli/`). An `agy` shim picks the profile and starts the real agy with that `HOME`. A shell bridge restores the real `HOME` in shells the agent spawns, so its Bash tool sees your normal environment.

POSIX `sh`, no dependencies.

## Install

With Homebrew:

```sh
brew install iamdin/tap/agyctl
agyctl install
```

`agyctl install` records the official agy and links the shim to `<data dir>/bin/agy` (default `~/.local/share/agyctl/bin/agy`). It then prints a line like this; put it at the **end** of your shell config (e.g. `~/.zshrc`) so the shim comes before the official agy in `PATH`. agyctl never edits your shell config.

```sh
export PATH="$HOME/.local/share/agyctl/bin:$PATH"
```

Then log in once per account (open a new shell first):

```sh
agyctl login work        # runs agy's native login in profile "work"
agyctl login personal
agyctl use work          # default profile
agyctl doctor            # checks that `agy` resolves to the shim
```

From a git clone instead of Homebrew:

```sh
git clone https://github.com/iamdin/agyctl && cd agyctl
./bin/agyctl install     # then add the printed PATH line; optionally symlink bin/agyctl onto PATH
```

Keep `bin/` and `runtime/` together; the scripts locate each other by resolving their own real path (symlinks are fine).

## Use

Profile choice: leading `--account NAME` > `AGY_PROFILE` > default (`agyctl use`).

```sh
agy                        # default profile
agy --account personal -p "hello"
AGY_PROFILE=work agy
```

`--account` is only read before any other argument (`--` ends it); everything after is passed to agy untouched. A bad or missing profile is an error, never a fallback to another one.

`agyctl list` shows profiles and whether the token file exists ("token file present", not proof of a valid login).

Data dir: `${AGYCTL_DATA_DIR:-~/.local/share/agyctl}` holding `real-agy`, `bin/agy`, `default`, `profiles/<name>/home/`.

## Tests

```sh
sh test/run.sh      # uses a fake agy; never runs the real one
```

## Known limits

- Not a security boundary (same UID).
- Only shells that read their startup files get the real `HOME`; programs agy runs directly, MCP servers, and agy's own file tools still see the profile `HOME`.
- Isolation relies on agy 1.5.6 falling back to per-`HOME` token files when the keychain is not reachable. Token refresh, logout, and agy upgrades are not yet verified.
- Each token save may wait about 5 seconds for the keychain timeout.
