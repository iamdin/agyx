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

Then log in once per profile:

```sh
agyx profile login work   # runs agy's native login in profile "work"
agyx profile login personal
agyx profile use work     # default profile
agyx doctor            # checks that `agyx` on PATH is this script
```

### Optional: take over the bare `agy` name

By default the official `agy` is left alone. `agyx shim` creates `<data dir>/bin/agy` (a link to the shim) and tells you that `<data dir>/bin` must now come **before** the real agy's directory in `PATH` (the official installer uses `~/.local/bin`, so put `export PATH="$HOME/.local/share/agyx/bin:$PATH"` at the end of your shell config). `agyx unshim` removes only that link (it refuses to remove anything that is not a symlink to the shim). Both are idempotent.

Inside an agent's shell, a nested `agyx` always routes to the inherited profile. A nested bare `agy` does only with the takeover on; without it, it runs the real agy with the real `HOME`, i.e. the default login, not the instance profile. `agyx doctor` reports which mode you are in.

From a git clone instead of Homebrew:

```sh
git clone https://github.com/iamdin/agyx && cd agyx
./bin/agyx setup       # then link bin/agyx onto PATH, e.g. ln -s "$PWD/bin/agyx" ~/.local/bin/agyx
```

Keep `bin/` and `runtime/` (including `runtime/sync.sh`) together; the scripts locate each other by resolving their own real path (symlinks are fine).

## Use

Profile choice: leading `--profile NAME` > `AGY_PROFILE` > default (`agyx profile use`).

`agyx` launches agy unless its first argument is one of its own management subcommands: `setup`, `doctor`, `shim`, `unshim`, `profile` (with `profile list`, `profile login NAME`, `profile use NAME`). None of them overlaps with a real agy subcommand (`acp`, `agent`, `agents`, `changelog`, `help`, `install`, `mcp`, `mic-serve`, `models`, `plugin`, `plugins`, `remote-control`, `update`) or flag (`-h`, `--help`), so all of those, and `agyx --help`, reach the real agy:

```sh
agyx                          # default profile
agyx --profile personal -p "hello"
AGY_PROFILE=work agyx --model x
agyx --profile work mcp list
agyx --help                  # agy's own help
agyx install                  # agy's own `install` subcommand
```

(After `agyx shim`, the same works with the bare `agy`.) The five management subcommand names are reserved and rejected as profile names.

### agyx usage

```
usage: agyx setup [path]        record the official agy (default: first agy in PATH)
       agyx profile login NAME  create profile NAME and log in with agy's native login
       agyx profile use NAME    set the default profile
       agyx profile list        list profiles and their Google accounts
       agyx doctor              check the installation
       agyx shim | unshim       enable / disable the optional bare 'agy' takeover
       agyx [--profile NAME] [agy args...]   anything else launches agy
```

This usage is printed (exit 2) on any misuse of a management subcommand: a missing, extra, invalid or reserved argument, or an unknown profile.

`--profile` is only read before any other argument (`--` ends it); everything after is passed to agy untouched. A bad or missing profile is an error, never a fallback to another one.

`agyx profile list` and `agyx doctor` show, per profile, which Google account it is logged in as:

```
work         you@example.com  (default)
personal     not logged in
old          token file present, email unknown
```

The email is read from the `id_token_email` field of the profile's agy token file with macOS `plutil` (no other dependency). No other field of that file is ever read or printed, in particular not the access or refresh tokens. "token file present, email unknown" means the file exists but the field could not be read; a present token file is not proof of a valid login. If two profiles report the same email, a `WARNING` line says both are logged in to the same Google account.

Data dir: `${AGYX_DATA_DIR:-~/.local/share/agyx}` holding `real-agy`, `bin/agy` (only after `agyx shim`), `default`, `profiles/<name>/home/`.

## Shared state and the home whitelist

A profile differs from your real home only in which Google account is logged in. On every launch, before starting agy, the shim makes this true with symlinks only (nothing is printed to stdout; warnings go to stderr):

**Shared `~/.gemini`.** `<profile home>/.gemini` and `.gemini/antigravity-cli` are real directories; every other entry in them is a symlink to the same entry in your real `~/.gemini` (settings, skills, MCP config, and so on). Entries that exist only in the profile are adopted: moved into the real `~/.gemini` and linked. If a profile copy replaced a link (agy saved the file by rename), the shim relinks it: an identical copy is simply relinked; a different one is relinked after the older version is kept in `<profile home>/agyx-drift/<path>.<timestamp>` (the newer one wins) and one warning is printed. A real directory where the shared side has an entry is never merged; it is left alone with a warning.

**Private to each profile** (never linked, moved or adopted): `antigravity-cli/antigravity-oauth-token` (the login), `antigravity-cli/log`, `antigravity-cli/cli.log` (agy keeps only a few log files per directory, so instances would evict each other) and `antigravity-cli/jetbox_summaries_proto.pb` (agy saves it by rename, so a link cannot survive).

**Home whitelist.** `<data dir>/home-links` lists names in your real home that are linked into every profile home, so programs agy starts directly (MCP servers) find your git, ssh, npm, bun, cargo and similar configuration. `agyx setup` writes the file with the default list if it does not exist, and the same default is used when the file is missing:

```
.gitconfig  .ssh  .config  .npm  .npmrc  .bun  .bunfig.toml  .cache  .cargo  .rustup  go  Code  GitHub
```

Edit the file to change the list: one name per line, `#` starts a comment line, blank lines are ignored. A name must be a single path component; `.`, `..`, names containing `/`, `.gemini`, `Library` and `.local` are skipped with a warning (`.local` holds the agyx data dir, so linking it would create a loop). On each launch a link is created when the real entry exists and the profile entry does not; a link whose real entry has disappeared is removed; anything else already in the profile home (a real file or directory, or a link elsewhere) is left untouched and reported as a conflict by `agyx doctor`. Links for names you later remove from the list stay in place.

`agyx doctor` also reports, per profile, shared `.gemini` entries that are not correct links (drift and real directories), the number of files in `agyx-drift`, and each whitelist name as linked, missing in the real home, not linked yet, or a conflict. In the steady state (everything already correct) the sync uses only shell builtins, no extra processes.

## The "Keychain Not Found" dialog

agy saves its token by calling `/usr/bin/security`. Under a profile `HOME` there is no default keychain, so macOS shows a "Keychain Not Found" dialog on every token save, and agy gives up after about 5 seconds and falls back to the token file.

To avoid this, on every launch the shim checks `<profile home>/Library/Keychains/login.keychain-db`. If it does not exist, it creates an empty keychain with an empty password and makes it the default and only keychain of that profile `HOME` (`security create-keychain`, `list-keychains`, `default-keychain`, `set-keychain-settings`, no auto-lock). Every `security` call runs with `HOME` set to the profile home and names the keychain by explicit path, so your real keychain and its search list are never touched, and items agy saves stay per profile. Existing profiles get their keychain on their next launch. If creation fails, agyx prints a warning and launches agy anyway.

`agyx doctor` reports, per profile, whether this keychain exists and is the default for that `HOME`, and warns if your real default keychain is inside the agyx data dir. The profile keychain has an empty password and is no secret store: same-user processes can open it, like the token files (see the limits below).

## Tests

```sh
sh test/run.sh      # uses a fake agy; never runs the real one
```

## Known limits

- Not a security boundary (same UID).
- Only shells that read their startup files get the real `HOME`; programs agy runs directly, MCP servers, and agy's own file tools still see the profile `HOME`.
- An MCP server (or any program agy starts directly) still sees the profile path in `$HOME`; the whitelist only makes your configuration reachable there. Keychain writes from such processes go to the profile keychain, not your login keychain.
- Settings changed in one running instance reach other profiles only when the change goes through the shared files; if agy replaced a link by rename, the change stays in that profile until its next launch, when the sync makes it shared (the older version is kept in `agyx-drift`).
- agy still keeps its token file (`<profile home>/.gemini/antigravity-cli/antigravity-oauth-token`) and loads from it when the profile keychain has no item; `agyx profile list` reads the email from that file only. A profile that is logged in only through its keychain would show "not logged in" there; agyx does not read keychain items.
- Token refresh, logout, and agy upgrades are not yet verified. If creating the profile keychain fails, agyx only warns and agy falls back to the token file (with the old 5-second wait and dialog).
