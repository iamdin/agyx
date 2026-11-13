# agyx

Run several official `agy` CLI (Google Antigravity CLI, macOS) instances at the same time under one macOS user, each logged in to a different Google account.

Each profile gets its own `HOME` and keychain (its Google login); the real `~/.gemini` is shared by all profiles. `agyx` runs a shim that picks the profile and starts the real agy with that `HOME`. A shell bridge restores the real `HOME` in shells the agent spawns, so its Bash tool sees your normal environment.

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

`agyx` launches agy unless its first argument is one of its own management subcommands: `doctor`, `profile` (with `profile list`, `profile login NAME`, `profile default [NAME]`), `uninstall`. `agyx --help`, `agyx -h` and `agyx help` (as the only argument) print agyx's own usage: read-only, no setup prompt, and they work before setup. None of the management subcommands overlaps with a real agy subcommand (`acp`, `agent`, `agents`, `changelog`, `install`, `mcp`, `mic-serve`, `models`, `plugin`, `plugins`, `remote-control`, `update`), so all of those reach the real agy:

```sh
agyx                          # default profile
agyx --profile personal -p "hello"
AGY_PROFILE=work agyx --model x
agyx --profile work mcp list
agyx --profile work --help   # agy's own help (a chosen profile passes --help through)
agyx install                  # agy's own `install` subcommand
```

(The same works with `<data dir>/bin/agy`.) The three management subcommand names (`doctor`, `profile`, `uninstall`) are reserved and rejected as profile names.

### agyx usage

```
usage: agyx [--profile NAME] [agy args...]   launch agy as a profile
       agyx profile login NAME      create profile NAME and log in with agy's native login
       agyx profile default [NAME]  show or set the default profile
       agyx profile list            list profiles and their Google accounts
       agyx doctor                  check the installation
       agyx uninstall               remove agyx's data and configuration
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

Data dir: `${AGYX_DATA_DIR:-~/.local/share/agyx}` holding `real-agy`, `bin/agy` (the shim entry), `default`, `profiles/<name>/home/` and `profiles/<name>/log/`.

## Shared state and the home whitelist

A profile differs from your real home only in which Google account is logged in. On every launch, before starting agy, the shim makes this true with symlinks only (nothing is printed to stdout; warnings go to stderr). Layout of `<data dir>/profiles/<name>/`:

```
home/.gemini            -> ~/.gemini          one symlink; everything agy keeps there is shared
home/<whitelist names>  -> ~/<name>           the symlinks file (below)
home/Library/Keychains/                       this account's keychain: the only private data
email                                         one line, the account email (not a secret)
log/cli-YYYYMMDD_HHMMSS.log                   this profile's agy logs, one file per launch
```

**Shared `~/.gemini`.** The whole real `~/.gemini` is shared by every profile: settings, skills, MCP config, history, logs. Whatever agy creates there lands in the shared tree immediately, so there is nothing to adopt, merge or back up at launch, and no `agyx-drift` directory. In the steady state a launch tests that one link and does nothing else.

**The token blocker.** agy reads its login from the keychain first and falls back to `~/.gemini/antigravity-cli/antigravity-oauth-token`, a file it writes when saving to the keychain fails. With a shared `.gemini` that file would be shared by every account. So agyx keeps a *directory* at that path (with a `README` explaining why), which makes the file fallback impossible: logins live only in each profile's own keychain. agyx creates the directory when it is missing. If a regular file is there instead (for example the plain agy fell back to a token file), no profile starts: agyx prints what it found, that every account could read it, and never reads the file, and, when run in a terminal, asks `Move it to the Trash? Plain agy will ask you to sign in again. [y/N]` (default No). Yes moves it to `~/.Trash/agyx-token-<timestamp>/` and the launch goes on; No, an empty answer, or no terminal (nothing is ever asked when output is piped, and `AGYX_ASSUME_YES` does not answer this one) stops the launch with a message that shows how to move it yourself. `agyx doctor` reports the blocker as ok, missing (created on next launch) or BLOCKING. Delete the directory only after uninstalling agyx. (This relies on how agy handles a failing token-file write; it is verified separately.)

**Migrating an existing profile.** A profile from 0.1.2 or earlier has a real `home/.gemini` directory. At its next launch agyx migrates it once: (0) the account email is saved to the `email` file from the profile's token file or log; (1) the old per-entry symlinks into `~/.gemini` are removed; (2) the profile's `antigravity-cli/log`, `cli.log`, `jetbox_summaries_proto.pb` and SQLite sidecars (`-wal`, `-shm`, `-journal`) go to the Trash; (3) a token file in the profile (its old fallback login) goes to the Trash, with a message saying whether its keychain holds a login or whether you may need `agyx profile login NAME` again; (4) every other entry is merged into `~/.gemini`: missing on the shared side is moved, identical files are dropped, of two different files the newer wins and the other goes to the Trash, a file against a directory sends the profile entry to the Trash, symlinks are moved as they are, and anything left over goes to the Trash; (5) the empty tree is removed and the link created. One stderr line per profile summarises it and names the Trash folder, `~/.Trash/agyx-<profile>-<timestamp>/` (relative paths kept; plain `mv`, so Finder's Put Back does not apply). A second launch changes nothing. Tests can redirect the Trash with `AGYX_TRASH_DIR`.

**Email.** After `agyx profile login NAME` succeeds, the account email is written to `<data dir>/profiles/NAME/email`: the last `email=` on an `applyAuthResult` line of the log files that login created in the profile's `log/` (every launch has its own file, so another agy instance logging in at the same time cannot be mistaken for it). If agy wrote nothing there, agyx falls back to the shared agy log files modified after the login started. `profile list` and `doctor` show that file; without it they fall back to the `id_token_email` field of a token file in the profile's own (not yet migrated) `.gemini`, and then to "logged in, email unknown". The duplicate-account warning uses the same source.

**Logs.** agyx only decides where agy writes its log: every launch gets a new file, `<data dir>/profiles/<name>/log/cli-YYYYMMDD_HHMMSS.log` (agy's own naming; a second launch in the same second gets a `_02`, `_03`, ... suffix), so two running instances never share a file and nothing is written to the shared `~/.gemini/antigravity-cli/log` or `cli.log`. agyx passes `--log-file <file>` to agy before your own arguments (agy rejects the flag after a subcommand), also for `acp`. It is not passed for `help`, `changelog`, `mcp`, `update`, `--help`, `-h` and `--version`, which write no log, or when you pass `--log-file` yourself. agyx never prunes, links or reads these files (except `profile login`, which reads the email from the files its own login created); delete old ones yourself. The newest log of each profile is on the `logs:` line of `agyx doctor`, or `ls -t <data dir>/profiles/NAME/log | head -n 1`. `agyx uninstall` removes the logs with the data dir.

**Home whitelist.** `${XDG_CONFIG_HOME:-$HOME/.config}/agyx/symlinks` (resolved from your real home, never from a profile home; `XDG_CONFIG_HOME` counts only when it is an absolute path) lists names in your real home that are linked into every profile home, so programs agy starts directly (MCP servers) find your git, ssh, npm, bun, cargo and similar configuration. agyx writes the file with the default list (creating the `agyx` directory) on any run when it does not exist, and the same default is used when it cannot be written; `agyx doctor` prints the resolved path. The default list:

```
.gitconfig  .ssh  .config  .npm  .npmrc  .bun  .bunfig.toml  .cache  .cargo  .rustup  go  Code  GitHub
```

Edit the file to change the list: one name per line, `#` starts a comment line, blank lines are ignored. A name must be a single path component; `.`, `..`, names containing `/`, `.gemini`, `Library` and `.local` are skipped with a warning (`.local` holds the agyx data dir, so linking it would create a loop). On each launch a link is created when the real entry exists and the profile entry does not; a link whose real entry has disappeared is removed; anything else already in the profile home (a real file or directory, or a link elsewhere) is left untouched and reported as a conflict by `agyx doctor`. Links for names you later remove from the list stay in place.

`agyx doctor` also reports the token blocker and, per profile, whether `.gemini` is the link to the shared tree (or a real directory that will be migrated at the next launch), and each whitelist name as linked, missing in the real home, not linked yet, or a conflict. In the steady state (everything already correct) the sync uses only shell builtins, no extra processes.

## The "Keychain Not Found" dialog

agy saves its token by calling `/usr/bin/security`. Under a profile `HOME` there is no default keychain, so macOS shows a "Keychain Not Found" dialog on every token save, and agy gives up after about 5 seconds and falls back to the token file.

To avoid this, on every launch the shim checks `<profile home>/Library/Keychains/login.keychain-db`. If it does not exist, it creates an empty keychain with an empty password and makes it the default and only keychain of that profile `HOME` (`security create-keychain`, `list-keychains`, `default-keychain`, `set-keychain-settings`, no auto-lock). Every `security` call runs with `HOME` set to the profile home and names the keychain by explicit path, so your real keychain and its search list are never touched, and items agy saves stay per profile. Existing profiles get their keychain on their next launch. If creation fails, agyx prints a warning and launches agy anyway.

`agyx doctor` reports, per profile, whether this keychain exists and is the default for that `HOME`, and warns if your real default keychain is inside the agyx data dir. The profile keychain has an empty password and is no secret store: same-user processes can open it, like the token files (see the limits below).

## Uninstall

`agyx uninstall` lists what it will remove and asks `Remove? [y/N]` (default No; without a terminal it refuses unless `AGYX_ASSUME_YES=1`). It refuses while an agy started through agyx is running. On yes it:

- deletes each profile's keychain (the Google logins agyx created; `security delete-keychain`, run with that profile's `HOME`),
- moves the data dir (`~/.local/share/agyx`) and the config dir (`~/.config/agyx`, your symlinks list) to `~/.Trash/agyx-uninstall-<timestamp>/`,
- removes the token blocker directory when it still holds only agyx's `README`,
- removes agyx itself when it can: `brew uninstall agyx` for a Homebrew install, the `~/.local/bin/agyx` link for a git checkout (the checkout stays), otherwise it tells you which path to delete.

It keeps `~/.gemini` (shared settings, history and conversations) and plain agy. Apps set up with `<data dir>/bin/agy` (for example T3 Code) stop working. Afterwards `brew untap iamdin/tap` is optional.

## What agyx changes on your system

- `~/.local/share/agyx` (or `AGYX_DATA_DIR`): the real agy path, the `bin/agy` entry, the default profile and `profiles/<name>/` with a private `HOME`, keychain and the agy log files of each profile.
- `~/.config/agyx/symlinks`: the home whitelist.
- `~/.gemini/antigravity-cli/antigravity-oauth-token/`: a directory with a `README` that stops agy from saving a login token file in the shared `~/.gemini` (see the token blocker above).
- Nothing else: no shell startup file is edited, no `PATH` change, no network access, nothing outside these paths except the Trash and the keychains inside the data dir. agyx reads a Google account email from a profile's log or token file, never the tokens.

## Tests

```sh
sh test/run.sh      # uses a fake agy; never runs the real one
```

## Known limits

- Not a security boundary (same UID). agyx makes no promise about Google's terms of service for running several accounts or instances; it does not proxy or rotate accounts, copy tokens, or work around any limit: each profile is just a separate normal login of the official agy.
- Only shells that read their startup files get the real `HOME`; programs agy runs directly, MCP servers, and agy's own file tools still see the profile `HOME`.
- An MCP server (or any program agy starts directly) still sees the profile path in `$HOME`; the whitelist only makes your configuration reachable there. Keychain writes from such processes go to the profile keychain, not your login keychain.
- A profile that still has the old real `.gemini` directory (a running agy writing into it) is migrated at its next launch; files agy has open keep being written to the old location until then.
- A profile counts as logged in when its keychain holds agy's login item (checked without reading the secret) or, before migration, a token file in its own `.gemini`. Token logins never live in `~/.gemini`: that is what the blocker is for.
- Token refresh, logout, and agy upgrades are not yet verified. If creating the profile keychain fails, agyx only warns and agy may not be able to save its login (with the old 5-second wait and dialog).

## License

MIT, see [LICENSE](LICENSE).
