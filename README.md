# agyx

Run several official `agy` CLI (Google Antigravity CLI, macOS) instances at the same time under one macOS user, each logged in to a different Google account.

Each profile gets its own `HOME` (agy keeps its OAuth token under `$HOME/.gemini/antigravity-cli/`). `agyx` runs a shim that picks the profile and starts the real agy with that `HOME`. A shell bridge restores the real `HOME` in shells the agent spawns, so its Bash tool sees your normal environment.

POSIX `sh`, no dependencies.

(Previously called agyctl.)

## Install

agyx needs the official Antigravity CLI (`agy`) installed first. Install it with Google's command (see the [Antigravity CLI docs](https://antigravity.google/docs/cli/overview) and the [repository README](https://github.com/google-antigravity/antigravity-cli#installation)):

```sh
curl -fsSL https://antigravity.google/cli/install.sh | bash
```

Then, with Homebrew:

```sh
brew tap iamdin/tap
brew trust iamdin/tap     # Homebrew 7 refuses formulas from an untrusted third-party tap until this runs
brew install agyx
agyx profile login work   # runs agy's native login in profile "work"
```

If `agy` is not installed, agyx prints this same pointer and exits without writing anything.

Nothing is written to your file system until you agree once. The first time you run a command that writes (launching agy, `agyx profile login`, `agyx profile default NAME`) and `<data dir>` does not exist yet, agyx prints what it will create and asks on the terminal (default yes):

```
agyx will set up:
  ~/.local/share/agyx/          profiles (one HOME and keychain per account), a link to agy at /path/to/agy
  ~/.local/share/agyx/bin/agy   entry for apps that need a binary named agy
  ~/.config/agyx/symlinks       home entries linked into every profile (editable)
Profiles share your ~/.gemini settings and history; your login keychain is not touched.
Continue? [Y/n]
```

No (or end of input) exits non-zero and writes nothing. Without a terminal (an app such as T3 Code, a pipe, ACP) agyx never asks: it exits non-zero with one stderr line saying it is not set up yet, and nothing on stdout. `AGYX_ASSUME_YES=1` skips the question (scripts, packaging). `agyx doctor`, `agyx profile list` and `agyx profile default` without a name are read-only: before setup they only report "not set up yet". A data dir that already exists counts as agreed and is never asked about. (`AGYX_TTY=<file>` replaces the terminal check and /dev/tty with a file the answer is read from; tests only.)

There is no setup command. `agyx` is the only command you run; Homebrew puts it on `PATH`, and agyx never edits your shell config. After the question, everything else happens by itself, on any run, and only prints to stderr:

- **Real agy.** The first time, agyx looks for the first executable `agy` on `PATH` (never its own entry point) and stores it as `<data dir>/real-agy`. After that there is no `PATH` scan. If agy is not installed, agyx says so and how to point it at one: `AGYX_REAL_AGY=/abs/path/to/agy` overrides everything (it is not stored).
- **A binary named `agy`.** `<data dir>/bin/agy` (default `~/.local/share/agyx/bin/agy`) is created when missing; it is a link to the shim. It is the path to give apps that need a binary named `agy` (for example a T3 Code "agy binary path" setting): they then start the real agy under the profile chosen by `AGY_PROFILE` or the default. `agyx doctor` prints it. Nothing asks you to change `PATH`.
- **Symlinks file.** `${XDG_CONFIG_HOME:-~/.config}/agyx/symlinks` is written with the default list when missing (see below), with one stderr line the first time.
- **First default.** `agyx profile login NAME` makes `NAME` the default profile when the login succeeded and no default is set yet. It never picks a default any other way.

Other commands: `agyx profile login personal`, `agyx profile default work` (without NAME: show it), `agyx doctor` (checks the installation, including that `agyx` on `PATH` is this script).

When no profile is chosen, agyx tells you what to do and exits non-zero without starting agy: with no profiles at all, run `agyx profile login NAME`; with profiles but no default, use `--profile NAME` or `agyx profile default NAME`; if the `default` file names a profile that does not exist, it says how to fix or create it. A profile that exists but is not logged in launches normally (agy asks you to log in).

Inside an agent's shell, a nested `agyx` or a bare `agy` started through `<data dir>/bin/agy` routes to the inherited profile; a bare `agy` found elsewhere on `PATH` is the real agy with the real `HOME`.

From a git clone instead of Homebrew:

```sh
git clone https://github.com/iamdin/agyx && cd agyx
ln -s "$PWD/bin/agyx" ~/.local/bin/agyx   # put bin/agyx on PATH
```

Keep `bin/` and `runtime/` (including `runtime/sync.sh`) together; the scripts locate each other by resolving their own real path (symlinks are fine).

Under Homebrew, everything agyx stores or passes on survives `brew upgrade` and `brew cleanup`: when its own resolved path is inside `<prefix>/Cellar/agyx/<version>/`, agyx uses the stable `<prefix>/opt/agyx/` path instead (for the `<data dir>/bin/agy` link and for the `ZDOTDIR` and `BASH_ENV` given to long-running agy processes). From a git checkout the resolved checkout path is used as it is. On every run, a `<data dir>/bin/agy` link that is dangling or points at another agyx location is repointed to the current entry; anything that is not an agyx entry is left alone and flagged by `agyx doctor`.

`agyx --version` prints `agyx <version>` and, when the real agy is found, its version too; `agyx doctor` prints the agyx version.

## Use

Profile choice: leading `--profile NAME` > `AGY_PROFILE` > default (`agyx profile default`).

`agyx` launches agy unless its first argument is one of its own management subcommands: `doctor`, `profile` (with `profile list`, `profile login NAME`, `profile default [NAME]`). `agyx --help`, `agyx -h` and `agyx help` (as the only argument) print agyx's own usage: read-only, no setup prompt, and they work before setup. None of the management subcommands overlaps with a real agy subcommand (`acp`, `agent`, `agents`, `changelog`, `install`, `mcp`, `mic-serve`, `models`, `plugin`, `plugins`, `remote-control`, `update`), so all of those reach the real agy:

```sh
agyx                          # default profile
agyx --profile personal -p "hello"
AGY_PROFILE=work agyx --model x
agyx --profile work mcp list
agyx --profile work --help   # agy's own help (a chosen profile passes --help through)
agyx install                  # agy's own `install` subcommand
```

(The same works with `<data dir>/bin/agy`.) The two management subcommand names (`doctor`, `profile`) are reserved and rejected as profile names.

### agyx usage

```
usage: agyx [--profile NAME] [agy args...]   launch agy as a profile
       agyx profile login NAME      create profile NAME and log in with agy's native login
       agyx profile default [NAME]  show or set the default profile
       agyx profile list            list profiles and their Google accounts
       agyx doctor                  check the installation
```

This usage is printed (exit 2) on any misuse of a management subcommand: a missing, extra, invalid or reserved argument, or an unknown profile.

`--profile` is only read before any other argument (`--` ends it); everything after is passed to agy untouched. A bad or missing profile is an error, never a fallback to another one.

`agyx profile list` and `agyx doctor` show, per profile, which Google account it is logged in as:

```
work         you@example.com  (default)
personal     not logged in
old          logged in, email unknown
```

A profile counts as logged in when its token file exists or its keychain holds agy's login item (service `gemini`, account `antigravity`; checked with `security find-generic-password` without `-w` or `-g`, so the secret is never read). The email is read from the `id_token_email` field of the token file with macOS `plutil` (no other dependency); when there is no token file (agy keeps the login in the profile keychain), it is the last `email=` on an `applyAuthResult` line of the newest file in `<profile home>/.gemini/antigravity-cli/log/`. No other field of that file is ever read or printed, in particular not the access or refresh tokens. "logged in, email unknown" means a login was found but no email could be read; a login found this way is not proof that it is still valid. If two profiles report the same email, a `WARNING` line says both are logged in to the same Google account.

Data dir: `${AGYX_DATA_DIR:-~/.local/share/agyx}` holding `real-agy`, `bin/agy` (the shim entry), `default`, `profiles/<name>/home/`.

## Shared state and the home whitelist

A profile differs from your real home only in which Google account is logged in. On every launch, before starting agy, the shim makes this true with symlinks only (nothing is printed to stdout; warnings go to stderr):

**Shared `~/.gemini`.** `<profile home>/.gemini` and `.gemini/antigravity-cli` are real directories; every other entry in them is a symlink to the same entry in your real `~/.gemini` (settings, skills, MCP config, and so on). Entries that exist only in the profile are adopted: moved into the real `~/.gemini` and linked. If a profile copy replaced a link (agy saved the file by rename), the shim relinks it: an identical copy is simply relinked; a different one is relinked after the older version is kept in `<profile home>/agyx-drift/<path>.<timestamp>` (the newer one wins) and one warning is printed. A real directory in the profile whose content is identical to the shared directory (for example a cache an editor integration wrote) is moved to `agyx-drift` and replaced by the link, silently; one that differs is never merged and is left alone with a warning.

**Private to each profile** (never linked, moved or adopted): `antigravity-cli/antigravity-oauth-token` (the login), `antigravity-cli/log`, `antigravity-cli/cli.log` (agy keeps only a few log files per directory, so instances would evict each other) and `antigravity-cli/jetbox_summaries_proto.pb` (agy saves it by rename, so a link cannot survive).

SQLite sidecar files (names ending in `-wal`, `-shm` or `-journal`) are never synced either, in any shared directory: SQLite opens the shared database through the profile symlink, resolves it, and creates those files next to the real database, so linking them would only produce links that dangle after a checkpoint.

**Home whitelist.** `${XDG_CONFIG_HOME:-$HOME/.config}/agyx/symlinks` (resolved from your real home, never from a profile home; `XDG_CONFIG_HOME` counts only when it is an absolute path) lists names in your real home that are linked into every profile home, so programs agy starts directly (MCP servers) find your git, ssh, npm, bun, cargo and similar configuration. agyx writes the file with the default list (creating the `agyx` directory) on any run when it does not exist, and the same default is used when it cannot be written; `agyx doctor` prints the resolved path. The default list:

```
.gitconfig  .ssh  .config  .npm  .npmrc  .bun  .bunfig.toml  .cache  .cargo  .rustup  go  Code  GitHub
```

Edit the file to change the list: one name per line, `#` starts a comment line, blank lines are ignored. A name must be a single path component; `.`, `..`, names containing `/`, `.gemini`, `Library` and `.local` are skipped with a warning (`.local` holds the agyx data dir, so linking it would create a loop). On each launch a link is created when the real entry exists and the profile entry does not; a link whose real entry has disappeared is removed; anything else already in the profile home (a real file or directory, or a link elsewhere) is left untouched and reported as a conflict by `agyx doctor`. Links for names you later remove from the list stay in place.

`agyx doctor` also reports, per profile, shared `.gemini` entries that are not correct links (drift and real directories) (a real directory identical to the shared one is reported as "identical, replaced by a link on next launch"), the number of files in `agyx-drift`, and each whitelist name as linked, missing in the real home, not linked yet, or a conflict. In the steady state (everything already correct) the sync uses only shell builtins, no extra processes.

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
- agy still keeps its token file (`<profile home>/.gemini/antigravity-cli/antigravity-oauth-token`) and loads from it when the profile keychain has no item. A profile counts as logged in when that file exists or its keychain holds agy's login item (checked without reading the secret); `agyx profile list` takes the email from the token file, else from agy's log, and shows "logged in, email unknown" when neither has one.
- Token refresh, logout, and agy upgrades are not yet verified. If creating the profile keychain fails, agyx only warns and agy falls back to the token file (with the old 5-second wait and dialog).

## License

MIT, see [LICENSE](LICENSE).
