# agyx

Run the official Google Antigravity CLI (`agy`, macOS) with several Google accounts under one macOS user. Each profile has its own file login and app settings. All profiles use your **real HOME** and share conversations, brain, history and MCP configuration. Plain `agy` keeps its normal login keychain and default app directory.

POSIX `sh`, no runtime dependencies. Previously called agyctl.

## Install and use

Install [the official agy](https://antigravity.google/docs/cli/overview) first:

```sh
curl -fsSL https://antigravity.google/cli/install.sh | bash
brew tap iamdin/tap
brew trust iamdin/tap   # required for a new third-party tap on Homebrew 7
brew install agyx
agyx profile login work
agyx profile login personal
agyx profile default work
```

This branch is an unreleased redesign; the published Homebrew version still uses the old layout. To test this checkout, use `/path/to/checkout/bin/agyx` instead. Keep `bin/` and `runtime/` together.

```sh
agyx                              # default profile
agyx --profile personal -p "hello"
AGY_PROFILE=work agyx --model x
agyx --profile work acp
agyx --profile work mcp list
agyx --profile work --help         # agy's help
agyx profile list
agyx doctor
```

Commands:

- `agyx [--profile NAME] [agy args...]`
- `agyx profile list | login NAME | default [NAME]`
- `agyx doctor`
- `agyx uninstall`
- `agyx --help`, `agyx --version`

Profile selection: leading `--profile NAME` (or `--profile=NAME`) > `AGY_PROFILE` > saved default. `--` ends profile parsing; remaining arguments are passed through. Names must match `[a-z][a-z0-9_-]{0,31}`; `profile`, `doctor` and `uninstall` are reserved. A missing or invalid profile is an error, not a fallback to another account. A logged-out profile starts agy's native sign-in. The first successful `profile login` becomes the default if none is set.

## Consent and paths

On first use, commands that write ask once before creating the data directory. No terminal means refusal and no writes. `AGYX_ASSUME_YES=1` skips the question for scripts. An existing data directory counts as consent, except that migration has its own question below. Help, version, list, doctor and showing the default do not set up a fresh installation. No shell startup files or PATH settings are edited.

Data directory: `${AGYX_DATA_DIR:-~/.local/share/agyx}`. `AGYX_REAL_AGY=/absolute/path/to/agy` overrides binary discovery; otherwise the first real agy on PATH is cached as `<data>/real-agy`. `<data>/bin/agy` is a shim for apps requiring a binary named agy (for example T3 Code). It uses the selected profile, just like agyx; agyx does not shadow plain agy on PATH. Its entry and shell bridge use the stable Homebrew `opt/agyx` path so they survive upgrades.

Layout:

```text
<data>/profiles/<name>/
  app/
    antigravity-oauth-token         private regular file, mode 0600
    settings.json                  private regular file
    jetski_state.pbtxt              private regular file
    jetbox_summaries_proto.pb       private regular file
    conversations -> ~/.gemini/antigravity-cli/conversations
    brain         -> ~/.gemini/antigravity-cli/brain
    history.jsonl -> ~/.gemini/antigravity-cli/history.jsonl
    ...           -> ~/.gemini/antigravity-cli/<same name>
  email                            account email from this login's log
  log/cli-YYYYMMDD_HHMMSS.log       separate agy log for each launch
```

The four private files are never linked from the shared directory. agyx never reads, copies or parses a token, including for the account email. "Logged in" means a regular profile token file exists, not proof the token is still valid. Email comes only from the `applyAuthResult email=` line in the log of that `profile login`; if unknown, list says so. Duplicate saved emails on logged-in profiles produce a warning.

At each launch agyx links missing shared app entries, including hidden entries, **except SQLite sidecars** (`*-wal`, `*-shm`, `*-journal`). Sidecars are never linked or adopted, doctor ignores them, and sync removes old broken sidecar links; real sidecar files are left to SQLite. A new non-private, non-sidecar file or directory created by agy is moved to the shared app directory and linked on the next launch if the shared name is absent. If both sides have an entry, neither is overwritten: `doctor` reports **DRIFT**. Unexpected/broken links are also reported, not silently replaced. Cross-account `--conversation` continuation uses the shared conversations. Avoid running concurrent first-time adoption of the same new entry; stop agy and resolve reported drift before continuing.

SQLite must resolve the profile database link to its shared canonical pathname before creating WAL/SHM/journal files. Verified with agy 1.5.7/1.5.8: two concurrent agy processes opened the same shared DB, WAL and SHM inodes, with no sidecars next to the profile link. The macOS SQLite regression test checks shared writer locking and integrity through two profile links. If agy replaces a DB link after a schema/open error, doctor reports drift; resolve it before continuing. Recheck canonical sidecar placement after SQLite/agy upgrades.

`~/.gemini/config/` remains shared. Settings saved by atomic rename belong to the profile: `settings.json`, `jetski_state.pbtxt` and `jetbox_summaries_proto.pb`. Other shared files must continue to be written in place by agy. There is no per-profile HOME, keychain or home whitelist in the new layout.

## How profile isolation works

For agy only, the shim supplies `WSL_DISTRO_NAME=agyx` when the existing value is empty/unset, and the hidden global flag `--app_data_dir=<relative path from ~/.gemini to profile/app>` **before all user arguments**. agy's WSL detector selects file token storage, so it does not load, save or remove the login keychain item. Existing nonempty WSL values and all SSH variables pass through unchanged. User `--app_data_dir` and `--gemini_dir` overrides are rejected because they could defeat isolation.

Bash and Zsh startup bridges restore the original WSL variable (including unset versus empty) and the original `BASH_ENV`/`ZDOTDIR`, then source the user's startup file. HOME is never redirected. Commands started inside these shells therefore see the normal environment. **Directly executed programs (including MCP servers), shells started without startup files, and POSIX sh can still inherit the fake WSL variable.** There is no general child-process environment hook in agy; the bridge cannot clean those processes. Their HOME is nevertheless the real HOME.

Each launch gets a unique private log; same-second launches get `_02`, `_03`, etc. The existing no-log list (`help`, `changelog`, `mcp`, `update`, `--help`, `-h`, `--version`) skips only the log flag, not the app-dir flag. An explicit user `--log-file` is kept. After a launch with a log file exits, agyx checks that this launch's log contains `Using file-based token storage` (WSL or SSH reason). If missing, it warns on stderr that keychain fallback can mix accounts and delete the profile token file. `doctor` applies the same check to each profile's newest log. This is an after-exit diagnostic, not prevention: stop using profiles if warned and check agy compatibility. Commands that produce no log cannot be checked. Logs are not pruned automatically.

## Migration from 0.1.3

Old profile keychain logins cannot be carried over. On the first invocation with legacy `profiles/<name>/home/` directories, agyx asks once for all profiles and explains that **each account must sign in again**. Without a terminal it refuses and changes nothing; `AGYX_ASSUME_YES=1` skips the question. Help/version do not migrate. Close old agy sessions before approving migration.

After consent, agyx:

1. Deletes each old profile keychain with `security delete-keychain`, its explicit path, and HOME set only to that old profile home. Failure stops migration; the real keychain is never deleted.
2. Moves each old `home/` to a unique `~/.Trash/agyx-<profile>-<timestamp>-*/home/` directory and creates `app/`. Saved email and logs stay.
3. Removes the old shared token blocker **only** when it contains exactly agyx's original README and nothing else. Plain agy's token files and unknown directories are untouched.
4. Moves the old `${XDG_CONFIG_HOME:-~/.config}/agyx/symlinks` whitelist file into the last profile's migration Trash folder, keeping its surrounding config directory.

List then reports the old profiles as not logged in. Run `agyx profile login NAME` for each one. Old leftovers live in the macOS Trash, never a backup directory under agyx. Test overrides `AGYX_REAL_HOME`, `AGYX_SECURITY`, `AGYX_TRASH_DIR` and `AGYX_TTY` are for isolated tests, not normal use.

## Doctor and uninstall

`doctor` reports agyx/agy versions, the real binary, shim entry, profile storage mode, default profile, token existence and mode (expected 0600), healthy/missing/broken links, drift, and newest log. A login keychain item `gemini/antigravity` is informational: plain agy may use it. Only item existence is checked, never its secret (`security` is never given `-w` or `-g`). Except for a consented legacy migration, doctor does not repair or write state.

`uninstall` asks for confirmation (default No), refusing without a terminal unless `AGYX_ASSUME_YES=1`. It refuses if a matching agy process is running. It moves the data directory, including profile token files and logs, to `~/.Trash/agyx-uninstall-<timestamp>-*/`. Tokens remain in the Trash until you empty it. It also handles remaining legacy keychains, whitelist and exact agyx blocker. Shared conversations/history, plain agy and unrelated config files stay untouched. Homebrew installations then run `brew uninstall agyx`; a checkout stays on disk (only an owned `~/.local/bin/agyx` link is removed). Apps using `<data>/bin/agy` will stop working.

## Risks and manual verification

- **Undocumented agy behavior:** both the WSL file-storage detector and hidden app-dir flag were checked on agy 1.5.7/1.5.8, not a stable public API. Recheck storage logs before using an agy upgrade. If Google changes either behavior, profile isolation could fail.
- Tokens are mode-0600 files, not a keychain secret. Same-user processes can read them. agyx is not a security boundary, account rotator or limit bypass.
- Real sign-in, refresh and logout require user testing. agyx never copies credentials or forces refresh by editing tokens. Concurrent writers to the same profile/private settings are not coordinated.
- Settings and summary protobuf files are now per-profile, unlike 0.1.3. Existing shared files are not copied into them.

Use a separate `AGYX_DATA_DIR` for a local checkout test. In your local terminal, then again in an SSH session on the second Mac (with that machine's checkout path):

```sh
export AGYX_DATA_DIR="$(mktemp -d /tmp/agyx-manual.XXXXXX)"
AX=/absolute/path/to/checkout/bin/agyx
"$AX" profile login accounta     # sign in as account A
"$AX" profile login accountb     # sign in as account B
"$AX" profile list
"$AX" --profile accounta         # confirm A in agy's account UI; create a conversation
"$AX" --profile accountb         # confirm B and shared conversation visibility
"$AX" --profile accountb --conversation CONVERSATION_ID
"$AX" doctor
```

In both sessions, ask agy to run a Bash/Zsh command that checks HOME and whether WSL_DISTRO_NAME is set; HOME must be real and the synthetic WSL value must be absent. Check profile logs for file-storage selection and the profile token path, not keychain selection. Do not print token files or entire process environments.

Test agy's native logout in account A, verify only A loses its login, then sign A back in; B and plain agy must stay logged in as before. To exercise refresh, leave both accounts signed in until the normal access-token lifetime expires (at least one hour), then issue an authenticated prompt in A and B separately and confirm identities again. There is no verified safe force-refresh flag: do not edit tokens, change the system clock or revoke Google grants just for this test. Afterwards close test sessions and move **only the temporary data directory** to the Trash; on the second Mac, also move only the temporary code directory there. Do **not** run `agyx uninstall` for test cleanup: even with a temporary `AGYX_DATA_DIR`, it removes the real global whitelist and token blocker still needed by an installed 0.1.3. For the temporary data directory created above:

```sh
case "$AGYX_DATA_DIR" in
  /tmp/agyx-manual.*)
    mkdir -p "$HOME/.Trash" &&
      trash=$(mktemp -d "$HOME/.Trash/agyx-manual-XXXXXX") &&
      mv "$AGYX_DATA_DIR" "$trash/data" && unset AGYX_DATA_DIR
    ;;
  *) printf 'Refusing: not the temporary test data directory\n' >&2 ;;
esac
```

Keep the real checkout, global config, shared app directory and installed agyx untouched. Test tokens remain in the Trash until you empty that specific test folder.

## ACP client lifetime

Keep ACP stdin open until the requested responses arrive. Writing `initialize` and `session/new` and then immediately sending EOF (for example `communicate(input=...)` or a short pipe) cancels agy's request context: agy 1.5.7/1.5.8 can return `-32000 Authentication required`, log `context cancelled, skipping keyring auth`, and only then log a loaded token. This reproduces with both file storage and plain agy using a disposable keychain, not only with agyx. Back-to-back requests with stdin kept open worked in both modes; agyx does not add an arbitrary delay or an ACP proxy.

## Tests

```sh
sh test/run.sh
sh test/release.sh
shellcheck -s sh -S warning bin/agy bin/agyx runtime/sync.sh runtime/bash_env runtime/zsh/.zshenv test/run.sh test/release.sh scripts/release.sh
```

Tests use stubs and temporary homes/data, with PATH excluding the real agy. Release tests use only throwaway local git repositories; they do not publish a release.

## License

MIT, see [LICENSE](LICENSE).
