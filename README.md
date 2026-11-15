# agyx

Run the official Google Antigravity CLI (`agy`, macOS & Linux) with several Google accounts under one OS user. Each profile has its own file login and app settings. All profiles use your **real HOME** and share conversations, brain, history and MCP configuration. Plain `agy` keeps its normal system keyring and default app directory.

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
AGYX_PROFILE=work agyx --model x
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

Profile selection: leading `--profile NAME` (or `--profile=NAME`) > `AGYX_PROFILE` > saved default. `--` ends profile parsing; remaining arguments are passed through. Names must match `[a-z][a-z0-9_-]{0,31}`; `profile`, `doctor` and `uninstall` are reserved. A missing or invalid profile is an error, not a fallback to another account. Use `AGYX_PROFILE` instead of the former `AGY_PROFILE`. A logged-out profile starts agy's native sign-in. The first successful `profile login` becomes the default if none is set.

## Consent and paths

On first use, commands that write ask once before creating the data directory. No terminal means refusal and no writes. `AGYX_ASSUME_YES=1` skips the question for scripts. An existing data directory counts as consent, except that migration and shared-entry repair ask separately. `--help` and `--version` never write to disk; `list`, `doctor` and showing the default do not set up a fresh installation, and only maintain `<data>/agy` (cleaning obsolete entry links) after any 0.1.x migration has been approved. No shell startup files or PATH settings are edited.

Data directory: `${AGYX_DATA_DIR:-~/.local/share/agyx}`. Give apps such as T3 Code **`<data>/agy`** (normally `~/.local/share/agyx/agy`), the only app shim. Each launch searches PATH for native agy, skipping agyx shims, then falls back to `~/.local/bin/agy` for GUI apps with a minimal PATH; `AGYX_REAL_AGY=/absolute/path/to/agy` overrides both. No binary path is cached, and invocation links are resolved before execution. The entry and shell bridge use Homebrew's stable `opt` path across upgrades; plain agy on PATH is not shadowed.

Once any legacy profiles are migrated, the next agyx command removes the old `<data>/real-agy` cache link and moves agyx's old `<data>/bin/agy` link (plus `bin/` if then empty) to the Trash without another prompt. Unrelated files, links and nonempty directories are preserved. Update apps still using the old entry path.

Profile directories and their `antigravity-cli/` directories are created with mode 0700. Layout:

```text
<data>/profiles/<name>/
  email                            account email from this login's log
  antigravity-cli/
    antigravity-oauth-token         private regular file, mode 0600
    settings.json                  private regular file
    jetski_state.pbtxt              private regular file
    jetbox_summaries_proto.pb       private regular file
    cache/                         private per-account cache (e.g. default_project_id.txt)
    log/ + cli.log                 private native agy logs (auto-pruned by agy)
    conversations -> ~/.gemini/antigravity-cli/conversations
    brain         -> ~/.gemini/antigravity-cli/brain
    history.jsonl -> ~/.gemini/antigravity-cli/history.jsonl
    ...           -> ~/.gemini/antigravity-cli/<same name>
```

Per-account private entries (`antigravity-oauth-token`, `settings.json`, `jetski_state.pbtxt`, `jetbox_summaries_proto.pb`, `cache`, `crashes`, `log`, `cli.log`, `updater`, `last_check.timestamp`) are never linked from the shared directory. agyx never reads, copies or parses a token, including for the account email. "Logged in" means a regular profile token file exists, not proof the token is still valid. Email comes only from the `applyAuthResult email=` line in the temporary log of that `profile login`; if unknown, list says so. Duplicate saved emails on logged-in profiles produce a warning.

Before agy starts, agyx creates and links the known shared directories, an empty history stream and SQLite database (agy initializes its schema), and a valid installation ID. Existing profile entries are adopted before creating empty targets. Other shared entries, including hidden ones, are linked too. **SQLite sidecars** (`*-wal`, `*-shm`, `*-journal`) are never linked or independently adopted; doctor ignores them and sync removes broken sidecar links.

If real entries exist on both sides, `doctor` reports **DRIFT**. The next launch asks once to repair all profiles (also before moving unlinked known entries); close all agy sessions first. Without a terminal it refuses to launch, leaving drift untouched; `AGYX_ASSUME_YES=1` skips the question. Directory contents merge recursively: newer conflicting entries win (shared wins ties), and the other copy goes to the Trash. History appends unique profile lines. The shared summary DB and other shared files stay; profile copies go to the Trash, with DB sidecars kept together. The four private files are untouched. Unexpected/broken links require manual attention. Preparation is serialized; native agy sessions can still run concurrently.

SQLite must resolve the profile database link to its shared canonical pathname before creating WAL/SHM/journal files. Verified with agy 1.5.7/1.5.8: two concurrent agy processes opened the same shared DB, WAL and SHM inodes, with no sidecars next to the profile link. The macOS SQLite regression test checks shared writer locking and integrity through two profile links. If agy replaces a DB link after a schema/open error, doctor reports drift; a consented repair preserves the shared DB and archives the profile DB. Recheck canonical sidecar placement after SQLite/agy upgrades.

`~/.gemini/config/` remains shared. Settings saved by atomic rename belong to the profile: `settings.json`, `jetski_state.pbtxt` and `jetbox_summaries_proto.pb`. Other shared files must continue to be written in place by agy. There is no per-profile HOME, keychain or home whitelist in the new layout.

## How profile isolation works

agyx chooses the least-invasive strategy for each platform and session:

- **Headless Linux, containers, and any SSH session (macOS or Linux):** `agy` natively selects file-based token storage (`no D-Bus session bus`, `container`, or `SSH` detector). agyx passes only `--app_data_dir=<relative path from ~/.gemini to profile/antigravity-cli>` **before all user arguments** — **no `WSL_*` variable, `ZDOTDIR`, or `BASH_ENV` bridge is set**.
- **Desktop sessions with an active OS keyring (local macOS, or Linux Desktop with D-Bus Secret Service):** agyx supplies `WSL_INTEROP=agyx` (ignored by Homebrew and common CLI tools unlike `WSL_DISTRO_NAME`) plus `--app_data_dir=...` so `agy` uses each profile's private token file without touching macOS Keychain or GNOME Keyring, while keeping local browser and ACP sign-in working. First-entry Bash and Zsh startup bridges immediately restore `WSL_INTEROP` and `BASH_ENV`/`ZDOTDIR`, remove all `AGYX_ORIG_*` context, and source the user's startup file.

User `--app_data_dir` and `--gemini_dir` overrides are rejected because they could defeat isolation. HOME is always real. `AGYX_PROFILE` remains for nested `agyx`; caller-supplied `AGYX_DATA_DIR`/`AGYX_REAL_AGY` remain for custom locations. Native `ANTIGRAVITY_*` and `AGY_CLI_*` variables are untouched.

Native agy manages and auto-prunes its own per-profile logs under `<profile>/antigravity-cli/log/`, and the shim `exec`s native agy directly (no wrapper process, no `--log-file` injection, preserving PID and signals). Before `exec`, agyx checks the profile's most recent non-empty log for `Using file-based token storage`; `profile login` checks its temporary login log immediately on exit, and `doctor` checks both the native binary's file-storage markers and each profile's newest log. Stop using profiles if warned and check agy compatibility.

## Migration from 0.1.3

Old profile keychain logins cannot be carried over. On the first invocation with legacy `profiles/<name>/home/` directories, agyx asks once for all profiles and explains that **each account must sign in again**. Without a terminal it refuses and changes nothing; `AGYX_ASSUME_YES=1` skips the question. Help/version do not migrate. Close old agy sessions before approving migration (migration checks open handles and refuses if busy).

After consent, agyx creates a single `~/.Trash/agyx-migrate-<timestamp>-*/` directory and:

1. Deletes each old profile keychain with `security delete-keychain`, its explicit path, and HOME set only to that old profile home. Failure stops migration; the real keychain is never deleted.
2. Moves each old `home/` (and any old outer `log/`) to `<migration-trash>/<profile>/` and creates `antigravity-cli/`. Saved email stays.
3. Removes the old shared token blocker **only** when it contains exactly agyx's original README and nothing else. Plain agy's token files and unknown directories are untouched.
4. Moves the old `${XDG_CONFIG_HOME:-~/.config}/agyx/symlinks` whitelist file to `<migration-trash>/symlinks`, keeping its surrounding config directory.

List then reports the old profiles as not logged in. Run `agyx profile login NAME` for each one. Displaced leftovers go to the OS Trash (`~/.Trash` on macOS, `${XDG_DATA_HOME:-~/.local/share}/Trash/files` on Linux), never a backup directory under agyx. Test overrides `AGYX_SECURITY`, `AGYX_TRASH_DIR` and `AGYX_TTY` are for isolated tests, not normal use.

## Doctor and uninstall

`doctor` reports agyx/agy versions, the real binary, shim entry, profile storage mode, default profile, token existence and mode (expected 0600), group/world-accessible profile directories (expected 0700), healthy/missing/broken links, drift, and newest log. A login keychain item `gemini/antigravity` is informational: plain agy may use it. Only item existence is checked, never its secret (`security` is never given `-w` or `-g`). Doctor does not repair profile data; it may maintain the app entry and clean its obsolete layout.

`uninstall` asks for confirmation (default No), refusing without a terminal unless `AGYX_ASSUME_YES=1`. It refuses if a matching agy process is running. It moves the data directory, including profile token files and logs, to `~/.Trash/agyx-uninstall-<timestamp>-*/`. Tokens remain in the Trash until you empty it. It also handles remaining legacy keychains, whitelist and exact agyx blocker. Shared conversations/history, plain agy and unrelated config files stay untouched. Homebrew installations then run `brew uninstall agyx`; a checkout stays on disk (only an owned `~/.local/bin/agyx` link is removed). Apps using `<data>/agy` will stop working.

## Security

Logins are stored as `0600` token files inside `0700` profile directories — the same format `agy` uses natively on Linux and SSH, with practical security comparable to the login keychain on an encrypted disk (like `~/.ssh` keys). Note that any process running as your OS user can read them: do not sync `~/.local/share/agyx` or back it up unencrypted, and empty the Trash after `agyx uninstall`.

## Risks and manual verification

- **Undocumented agy behavior:** both the WSL file-storage detector and hidden app-dir flag were checked on agy 1.5.7/1.5.8, not a stable public API. Recheck storage logs before using an agy upgrade. If Google changes either behavior, profile isolation could fail.
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

## Tests

```sh
sh test/run.sh
sh test/release.sh
shellcheck -s sh -S warning bin/agy bin/agyx runtime/sync.sh runtime/legacy.sh runtime/bash_env runtime/zsh/.zshenv test/run.sh test/release.sh scripts/release.sh
```

Tests use stubs and temporary homes/data, with PATH excluding the real agy. Release tests use only throwaway local git repositories; they do not publish a release.

## License

MIT, see [LICENSE](LICENSE).
