#!/bin/sh
# shellcheck disable=SC3013 # -ef/-nt are POSIX.1-2024 ( omitted only in older ShellCheck < 0.10 )
# Offline tests. PATH excludes the real agy; every security call uses a stub.
umask 022
here=$(cd "$(dirname "$0")/.." && pwd -P)
T=$(mktemp -d) || exit 1
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT
export HOME=$T/home AGYX_DATA_DIR=$T/data AGYX_TRASH_DIR=$T/trash
export SECLOG=$T/security.log AGYX_SECURITY=$T/security AGYX_REAL_AGY=$T/fake-agy AGYX_DOCKERENV=$T/no-docker DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/fake-bus
unset AGYX_PROFILE AGY_PROFILE AGYX_REAL_HOME WSL_DISTRO_NAME WSL_INTEROP SSH_CLIENT SSH_CONNECTION SSH_TTY ZDOTDIR BASH_ENV XDG_CONFIG_HOME XDG_DATA_HOME XDG_RUNTIME_DIR
unset AGYX_ASSUME_YES AGYX_TTY AGYX_ORIG_WSL_INTEROP AGYX_ORIG_ZDOTDIR AGYX_ORIG_BASH_ENV
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
mkdir -p "$HOME" "$AGYX_DATA_DIR/profiles/work/antigravity-cli" "$AGYX_DATA_DIR/profiles/personal/antigravity-cli" "$AGYX_TRASH_DIR"
RH=$HOME DD=$AGYX_DATA_DIR
cat > "$T/fake-agy" <<'EOF'
#!/bin/sh
# Markers checked by agyx doctor: WSL_INTEROP app_data_dir Using file-based token storage
app= log=
for a in "$@"; do case $a in --app_data_dir=*) app=${a#*=} ;; esac; done
prev=
for a in "$@"; do
  [ "$prev" != --log-file ] || log=$a
  case $a in --log-file=*) log=${a#*=} ;; esac
  prev=$a
done
[ -z "$app" ] || app=$HOME/.gemini/$app
export FAKE_APP=$app
if [ -z "$log" ] && [ -n "$app" ]; then
  case ${1-} in
    help|changelog|mcp|update|--help|-h|--version) ;;
    *)
      mkdir -p "$app/log"
      log=$app/log/cli-native.log
      ln -sfn log/cli-native.log "$app/cli.log"
      ;;
  esac
fi
if [ -n "$log" ]; then
  case ${FAKE_STORAGE:-WSL} in
    missing) ;;
    keychain) printf 'Using keychain token storage\n' > "$log" ;;
    *) printf 'Using file-based token storage because %s environment detected\n' "${FAKE_STORAGE:-WSL}" > "$log" ;;
  esac
fi
if [ "${FAKE_LOGIN-}" = 1 ]; then
  (umask 077; printf 'not-a-real-token\n' > "$app/antigravity-oauth-token")
  printf 'applyAuthResult ok email=%s\n' "${FAKE_EMAIL-own@example.com}" >> "$log"
  exit 0
fi
if [ -n "${FAKE_RUN-}" ]; then exec /bin/sh -c "$FAKE_RUN"; fi
printf 'EXE=%s\n' "$0"
printf 'HOME=%s\nPROFILE=%s\nWSL_INTEROP=%s\nWSL_DISTRO=%s\nZDOTDIR=%s\nBASH_ENV=%s\nSSH_CLIENT=%s\nSSH_CONNECTION=%s\nSSH_TTY=%s\n' "$HOME" "$AGYX_PROFILE" "${WSL_INTEROP-unset}" "${WSL_DISTRO_NAME-unset}" "${ZDOTDIR-unset}" "${BASH_ENV-unset}" "${SSH_CLIENT-unset}" "${SSH_CONNECTION-unset}" "${SSH_TTY-unset}"
for a in "$@"; do printf 'ARG=%s\n' "$a"; done
exit "${FAKE_STATUS:-0}"
EOF
cat > "$T/security" <<'EOF'
#!/bin/sh
printf 'HOME=%s %s\n' "$HOME" "$*" >> "$SECLOG"
case $1 in
  find-generic-password) [ "${FAKE_KEYCHAIN_ITEM-}" = 1 ] ;;
  *) exit 99 ;;
esac
EOF
chmod +x "$T/fake-agy" "$T/security"
: > "$SECLOG"
printf 'work\n' > "$DD/default"
ax() { "$here/bin/agyx" "$@"; }
launch() { "$here/bin/agy" "$@"; }
pass=0 fail=0
mode_of() { if [ "$(uname -s)" = Darwin ]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi; }
stamp_of() { if [ "$(uname -s)" = Darwin ]; then stat -f '%i:%p:%m:%z' "$@"; else stat -c '%i:%f:%Y:%s' "$@"; fi; }
eq() {
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3"; fi
}
field() { launch "$@" | sed -n "s/^$FIELD=//p"; }
prof() { FIELD=PROFILE field "$@"; }
err() {
  _name=$1; shift
  _out=$("$@" 2>"$T/err"); _rc=$?
  eq "$_name" 'nonzero,empty,stderr' "$([ "$_rc" -ne 0 ] && echo nonzero),$([ -z "$_out" ] && echo empty),$([ -s "$T/err" ] && echo stderr)"
}
# Profile selection, validation, untouched user arguments.
eq default work "$(prof)"
eq env personal "$(AGYX_PROFILE=personal prof)"
eq flag work "$(AGYX_PROFILE=personal prof --profile=work)"
eq old-profile-env-ignored work "$(AGY_PROFILE=personal prof)"
eq real-home "$RH" "$(FIELD=HOME field)"
eq desktop-wsl-interop agyx "$(FIELD=WSL_INTEROP field)"
eq desktop-no-wsl-distro unset "$(FIELD=WSL_DISTRO field)"
eq wsl-interop-existing /run/WSL/1 "$(WSL_INTEROP=/run/WSL/1 FIELD=WSL_INTEROP field)"
eq wsl-interop-empty agyx "$(WSL_INTEROP='' FIELD=WSL_INTEROP field)"
# Per-platform native bypass: SSH, container, and headless Linux inject NEITHER WSL_* NOR ZDOTDIR/BASH_ENV.
eq ssh-zero-bridge 'unset|unset|unset' "$(SSH_CLIENT='1.2.3.4 1 22' launch | awk -F= '/^(WSL_INTEROP|ZDOTDIR|BASH_ENV)=/{printf "%s|", $2}' | sed 's/|$//')"
if [ "$(uname -s)" = Linux ]; then
  eq linux-headless-zero-bridge 'unset|unset|unset' "$(DBUS_SESSION_BUS_ADDRESS='' XDG_RUNTIME_DIR="$T/no-bus" launch | awk -F= '/^(WSL_INTEROP|ZDOTDIR|BASH_ENV)=/{printf "%s|", $2}' | sed 's/|$//')"
fi
eq desktop-uses-bridge agyx "$(DBUS_SESSION_BUS_ADDRESS='unix:path=/tmp/bus' FIELD=WSL_INTEROP field)"
touch "$T/fake-dockerenv"
eq container-zero-bridge 'unset|unset|unset' "$(AGYX_DOCKERENV="$T/fake-dockerenv" launch | awk -F= '/^(WSL_INTEROP|ZDOTDIR|BASH_ENV)=/{printf "%s|", $2}' | sed 's/|$//')"
for bad in Work 1a a/b doctor profile setup uninstall ''; do err "profile-$bad" launch --profile "$bad"; done
err missing launch --profile
err duplicate launch --profile work --profile personal
err missing-dir launch --profile absent
err env-invalid env AGYX_PROFILE=BAD "$here/bin/agy"
mv "$DD/default" "$T/default"
err no-default launch
mv "$T/default" "$DD/default"
# A single entry, uncached PATH discovery and the official GUI fallback.
eq single-entry "$here/bin/agy" "$(readlink "$DD/agy")"
eq no-real-cache no "$([ -e "$DD/real-agy" ] || [ -L "$DD/real-agy" ] && echo yes || echo no)"
mkdir -p "$T/native one" "$T/native-two" "$RH/.local/bin" "$T/old/bin" "$T/old/runtime" "$T/alias"
cp "$T/fake-agy" "$T/native one/agy"
cp "$T/fake-agy" "$T/native-two/agy"
cp "$T/fake-agy" "$RH/.local/bin/agy"
cp "$here/bin/agy" "$here/bin/agyx" "$T/old/bin/"
cp "$here/runtime/"*.sh "$T/old/runtime/"
ln -s '../native one/agy' "$T/alias/agy"
eq path-native-first "$T/native one/agy" "$(AGYX_REAL_AGY='' PATH="$DD:$T/old/bin:$T/native one:$PATH" FIELD=EXE field)"
eq path-reread-next-launch "$T/native-two/agy" "$(AGYX_REAL_AGY='' PATH="$T/native-two:$PATH" FIELD=EXE field)"
eq native-alias-resolved "$T/native one/agy" "$(AGYX_REAL_AGY='' PATH="$T/alias:$PATH" FIELD=EXE field)"
mkdir "$T/literal[one]" "$T/literaln"
cp "$T/fake-agy" "$T/literal[one]/agy"
cp "$T/fake-agy" "$T/literaln/agy"
eq path-literal-no-globbing "$T/literal[one]/agy" "$(AGYX_REAL_AGY='' PATH="$T/literal[one]:$PATH" FIELD=EXE field)"
eq native-override-resolved "$T/native one/agy" "$(AGYX_REAL_AGY="$T/alias/agy" FIELD=EXE field)"
eq native-override-wins "$T/fake-agy" "$(PATH="$T/native-two:$PATH" FIELD=EXE field)"
eq minimal-path-fallback "$RH/.local/bin/agy" "$(AGYX_REAL_AGY='' FIELD=EXE field)"
eq skip-only-shims-to-fallback "$RH/.local/bin/agy" "$(AGYX_REAL_AGY='' PATH="$DD:$T/old/bin:$PATH" FIELD=EXE field)"
# A real binary beside an agyx runtime is still native, not an agyx shell shim.
mkdir -p "$T/collocated/bin" "$T/collocated/runtime"
cp /usr/bin/true "$T/collocated/bin/agy"
cp "$here/runtime/"*.sh "$T/collocated/runtime/"
( . "$here/runtime/sync.sh"; AGYX_SHIM=$here/bin/agy; agyx_real_candidate "$T/collocated/bin/agy" ); rc=$?
eq native-not-rejected-by-runtime-neighbor 0 "$rc"
err override-current-shim env AGYX_REAL_AGY="$DD/agy" "$here/bin/agy" --profile work
err override-other-shim env AGYX_REAL_AGY="$T/old/bin/agy" "$here/bin/agy" --profile work
ln -s "$here/bin/agyx" "$T/alias/management"
err override-management-shim env AGYX_REAL_AGY="$T/alias/management" "$here/bin/agy" --profile work
err override-missing-no-fallback env AGYX_REAL_AGY="$T/missing-agy" "$here/bin/agy" --profile work
eq doctor-new-entry 1 "$(ax doctor 2>/dev/null | grep -c "agy entry: $DD/agy (in place")"
eq doctor-native-fallback 1 "$(AGYX_REAL_AGY='' ax doctor 2>/dev/null | grep -c "^real agy: $RH/.local/bin/agy$")"
eq version-string 1 "$(ax --version | grep -c '^agyx 0.2.1$')"
# Only doctor above queried item existence; launches still must make no security calls.
eq doctor-item-queries-only 2 "$(wc -l < "$SECLOG" | tr -d ' ')"
: > "$SECLOG"
# Help/version are strictly read-only (no disk cleanup / migration).
mkdir -p "$DD/bin" "$DD/profiles/work/log"
printf oldlog > "$DD/profiles/work/log/cli-old.log"
printf stamp > "$DD/.verified"
ln -s "$T/native one/agy" "$DD/real-agy"
ln -s "$here/bin/agy" "$DD/bin/agy"
ax --version >/dev/null
ax --help >/dev/null
eq help-version-readonly yes "$([ -L "$DD/real-agy" ] && [ -L "$DD/bin/agy" ] && [ -f "$DD/.verified" ] && [ -d "$DD/profiles/work/log" ] && echo yes)"
# Unrelated leftover files under the data dir are left alone; only <data>/agy is managed.
printf unrelated-cache > "$DD/real-agy"
launch >/dev/null
eq unrelated-cache-file-kept unrelated-cache "$(cat "$DD/real-agy")"
rm -f "$DD/real-agy" "$DD/.verified" "${DD:?}/bin/agy"
rmdir "${DD:?}/bin" 2>/dev/null || true
rm -rf "${DD:?}/profiles/work/log"
rm "$DD/agy"; printf custom-entry > "$DD/agy"
launch >/dev/null
eq unrelated-new-entry-kept custom-entry "$(cat "$DD/agy")"
rm "$DD/agy"; ln -s "$DD/agy" "$DD/agy"
launch >/dev/null
eq cyclic-entry-not-overwritten "$DD/agy" "$(readlink "$DD/agy")"
rm "$DD/agy"; ln -s "$here/bin/agy" "$DD/agy"
err official-missing env HOME="$T/no-native-home" AGYX_DATA_DIR="$T/no-native-data" AGYX_REAL_AGY='' "$here/bin/agyx" profile login p
eq missing-native-no-setup no "$([ -e "$T/no-native-data" ] && echo yes || echo no)"
(env AGYX_DATA_DIR="$T/gui-data" AGYX_REAL_AGY='' AGYX_ASSUME_YES=1 FAKE_LOGIN=1 "$here/bin/agyx" profile login p >/dev/null)
eq gui-first-setup-entry "$here/bin/agy" "$(readlink "$T/gui-data/agy")"
# The app flag precedes all subcommands; agyx never injects --log-file (native agy manages logs).
for cmd in interactive -p acp mcp login logout models agent agents plugins plugin remote-control mic-serve install help changelog update --help -h --version; do
  if [ "$cmd" = interactive ]; then out=$(launch); else out=$(launch "$cmd"); fi
  first=$(printf '%s\n' "$out" | grep '^ARG=' | head -n 1)
  eq "app-first-$cmd" 1 "$(printf '%s\n' "$first" | grep -c '^ARG=--app_data_dir=')"
  eq "no-injected-log-$cmd" 0 "$(printf '%s\n' "$out" | grep -c '^ARG=--log-file$')"
done
out=$(launch --profile work -- 'hello world' '' --profile personal -- x)
eq argv 'ARG=hello world|ARG=|ARG=--profile|ARG=personal|ARG=--|ARG=x|' "$(printf '%s\n' "$out" | grep '^ARG=' | tail -n 6 | tr '\n' '|')"
eq own-log 1 "$(launch --log-file "$T/own.log" | grep -c '^ARG=--log-file$')"
err override-app launch --app_data_dir=elsewhere
err override-gemini launch --gemini_dir /elsewhere
err override-single-dash launch -app_data_dir=elsewhere
# Resolve the relative argument, including spaces and data outside HOME.
out=$(launch)
rel=$(printf '%s\n' "$out" | sed -n 's/^ARG=--app_data_dir=//p')
eq relative-target "$(cd "$DD/profiles/work/antigravity-cli" && pwd -P)" "$(cd "$RH/.gemini/$rel" && pwd -P)"
mkdir -p "$T/space data/profiles/p/antigravity-cli"
out=$(AGYX_DATA_DIR="$T/space data" launch --profile p)
rel=$(printf '%s\n' "$out" | sed -n 's/^ARG=--app_data_dir=//p')
eq space-target "$(cd "$T/space data/profiles/p/antigravity-cli" && pwd -P)" "$(cd "$RH/.gemini/$rel" && pwd -P)"
eq no-keychain-launches '' "$(cat "$SECLOG")"
# SSH passthrough is byte-for-byte, including an empty variable.
out=$(SSH_CLIENT='client value' SSH_CONNECTION='connection value' SSH_TTY='' launch)
eq ssh 'SSH_CLIENT=client value|SSH_CONNECTION=connection value|SSH_TTY=|' "$(printf '%s\n' "$out" | grep '^SSH_' | tr '\n' '|')"
# Desktop mode Bash/Zsh bridge restores unset/empty/existing WSL_INTEROP and user's startup variables, even nested.
for shell in bash zsh; do
  command -v "$shell" >/dev/null || { echo "SKIP $shell"; continue; }
  snippet="$shell -c 'printf \"%s|%s|%s|%s\" \"\$HOME\" \"\${WSL_INTEROP-unset}\" \"\${ZDOTDIR-unset}\" \"\${BASH_ENV-unset}\"'"
  eq "$shell-unset" "$RH|unset|unset|unset" "$(FAKE_RUN="$snippet" launch)"
  eq "$shell-empty" "$RH|||" "$(WSL_INTEROP='' ZDOTDIR='' BASH_ENV='' FAKE_RUN="$snippet" launch)"
  eq "$shell-existing" "$RH|/run/WSL/9|/zd|/be" "$(WSL_INTEROP=/run/WSL/9 ZDOTDIR=/zd BASH_ENV=/be FAKE_RUN="$snippet" launch)"
  nested="$shell -c 'FAKE_RUN= AGYX_DOCKERENV=\"$T/no-docker\" \"$here/bin/agy\" --profile personal'"
  eq "$shell-nested" personal "$(FAKE_RUN="$nested" launch | sed -n 's/^PROFILE=//p')"
  nested="$shell -c 'FAKE_RUN= AGYX_DOCKERENV=\"$T/no-docker\" \"$here/bin/agy\"'"
  eq "$shell-nested-inherits-profile" personal "$(FAKE_RUN="$nested" launch --profile personal | sed -n 's/^PROFILE=//p')"
  if [ "$shell" = bash ]; then names='compgen -A variable AGYX_ORIG_ || :'
  else names='print -rl -- ${(k)parameters[(I)AGYX_ORIG_*]}'; fi
  eq "$shell-originals-cleaned" '' "$(AGYX_ORIG_EXTRA=probe FAKE_RUN="$shell -c '$names'" launch)"
  eq "$shell-home-helper-cleaned" unset "$(AGYX_REAL_HOME=/unused FAKE_RUN="$shell -c 'printf %s \${AGYX_REAL_HOME-unset}'" launch)"
  if [ "$shell" = bash ]; then routing='compgen -e AGYX_'
  else routing='print -rl -- ${(k)parameters[(I)AGYX_*]}'; fi
  eq "$shell-routing-vars-only" 'AGYX_DATA_DIR AGYX_PROFILE AGYX_REAL_AGY ' "$(FAKE_RUN="$shell -c '$routing'" launch | sort | tr '\n' ' ')"
  eq "$shell-native-env-kept" '/native-api|kept' "$(ANTIGRAVITY_AGENTAPI_EXE=/native-api AGY_CLI_PROBE=kept FAKE_RUN="$shell -c 'printf \"%s|%s\" \"\$ANTIGRAVITY_AGENTAPI_EXE\" \"\$AGY_CLI_PROBE\"'" launch)"
done
mkdir -p "$T/zd"
printf '[ ! "${AGYX_ORIG_WSL_INTEROP+x}" ] || printf leak >> "$COUNT"\nprintf x >> "$COUNT"\n' > "$T/zd/.zshenv"
printf '[ ! "${AGYX_ORIG_WSL_INTEROP+x}" ] || printf leak >> "$COUNT"\nprintf x >> "$COUNT"\n' > "$T/benv"
export COUNT=$T/count
if command -v zsh >/dev/null 2>&1; then
  : > "$COUNT"
  (ZDOTDIR=$T/zd FAKE_RUN='zsh -c true' launch >/dev/null)
  eq zshenv-once x "$(cat "$COUNT")"
fi
: > "$COUNT"
(BASH_ENV=$T/benv FAKE_RUN='bash -c true' launch >/dev/null)
eq bashenv-once x "$(cat "$COUNT")"
# Share database files, but never link/adopt SQLite sidecars (SQLite owns their lifecycle).
shared=$RH/.gemini/antigravity-cli app=$DD/profiles/work/antigravity-cli
mkdir -p "$shared/conversations" "$shared/brain"
printf history > "$shared/history.jsonl"
printf database > "$shared/conversation_summaries.db"
printf wal > "$shared/conversation_summaries.db-wal"
printf hidden > "$shared/.hidden"
for private in antigravity-oauth-token settings.json jetski_state.pbtxt jetbox_summaries_proto.pb; do
  (umask 077; printf private > "$shared/$private")
done
launch >/dev/null
for entry in conversations brain history.jsonl conversation_summaries.db .hidden; do
  eq "link-$entry" "$shared/$entry" "$(readlink "$app/$entry")"
done
for suffix in wal shm journal; do
  printf sidecar > "$shared/conversation_summaries.db-$suffix"
  printf local > "$app/local.db-$suffix"
  ln -s "$shared/deleted.db-$suffix" "$app/deleted.db-$suffix"
done
launch >/dev/null
for suffix in wal shm journal; do
  eq "sidecar-not-linked-$suffix" no "$([ -L "$app/conversation_summaries.db-$suffix" ] && echo yes || echo no)"
  eq "sidecar-broken-link-cleaned-$suffix" no "$([ -L "$app/deleted.db-$suffix" ] && echo yes || echo no)"
  eq "sidecar-not-adopted-$suffix" no "$([ -e "$shared/local.db-$suffix" ] && echo yes || echo no)"
  eq "sidecar-local-preserved-$suffix" local "$(cat "$app/local.db-$suffix")"
  ln -s "$shared/missing.db-$suffix" "$app/doctor.db-$suffix"
done
eq doctor-ignores-sidecars 0 "$(ax doctor 2>/dev/null | grep -Ec 'antigravity-cli .*(-wal|-shm|-journal):')"
# SQLite resolves the DB link before deriving WAL/SHM names and taking locks.
if command -v sqlite3 >/dev/null 2>&1; then
  mkdir -p "$T/sqlite/shared" "$T/sqlite/one" "$T/sqlite/two"
  sqldb=$T/sqlite/shared/test.db
  sqlite3 "$sqldb" 'PRAGMA journal_mode=WAL; CREATE TABLE t(n);' >/dev/null
  ln -s "$sqldb" "$T/sqlite/one/test.db"
  ln -s "$sqldb" "$T/sqlite/two/test.db"
  sqlite3 "$T/sqlite/one/test.db" <<EOF &
BEGIN IMMEDIATE;
INSERT INTO t VALUES(1);
.shell touch "$T/sqlite/ready"
.shell sleep 1
COMMIT;
EOF
  sqlite_pid=$!
  i=0
  while [ ! -f "$T/sqlite/ready" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  eq sqlite-shared-wal-shm yes "$([ -f "$sqldb-wal" ] && [ -f "$sqldb-shm" ] && echo yes)"
  eq sqlite-no-profile-sidecars no "$(find "$T/sqlite/one" "$T/sqlite/two" -type f | grep -q . && echo yes || echo no)"
  sqlite3 "$T/sqlite/two/test.db" 'BEGIN IMMEDIATE;' 2>"$T/sqlite/error"; rc=$?
  eq sqlite-shared-writer-lock 1 "$([ "$rc" -ne 0 ] && grep -q 'database is locked' "$T/sqlite/error" && echo 1)"
  wait "$sqlite_pid"; rc=$?
  eq sqlite-first-commit 0 "$rc"
  sqlite3 "$T/sqlite/two/test.db" 'BEGIN IMMEDIATE; INSERT INTO t VALUES(2); COMMIT;'
  eq sqlite-both-writes-visible 2 "$(sqlite3 "$sqldb" 'SELECT count(*) FROM t;')"
  eq sqlite-integrity ok "$(sqlite3 "$sqldb" 'PRAGMA integrity_check;')"
else
  echo "SKIP sqlite3"
fi
for private in antigravity-oauth-token settings.json jetski_state.pbtxt jetbox_summaries_proto.pb; do
  eq "not-shared-$private" no "$([ -e "$app/$private" ] && echo yes || echo no)"
done
# Per-account cache/log/updater links from older betas are automatically detached to stay private.
mkdir -p "$shared/cache"
printf shared-proj > "$shared/cache/default_project_id.txt"
ln -s "$shared/cache" "$app/cache"
launch >/dev/null
eq former-shared-cache-detached no "$([ -L "$app/cache" ] && echo yes || echo no)"
mkdir -p "$app/cache"
printf work-proj > "$app/cache/default_project_id.txt"
launch >/dev/null
eq private-cache-not-adopted shared-proj "$(cat "$shared/cache/default_project_id.txt")"
eq private-cache-kept work-proj "$(cat "$app/cache/default_project_id.txt")"
printf newly-created > "$app/future-entry"
printf future-db > "$app/future.db"
printf future-wal > "$app/future.db-wal"
launch >/dev/null
eq adopted newly-created "$(cat "$shared/future-entry")"
eq adoption-link "$shared/future-entry" "$(readlink "$app/future-entry")"
eq adopted-db-with-wal 'future-db,future-wal' "$(cat "$shared/future.db"),$(cat "$shared/future.db-wal")"
eq adopted-db-link "$shared/future.db" "$(readlink "$app/future.db")"
rm "$app/conversation_summaries.db"
printf replaced-db > "$app/conversation_summaries.db"
eq doctor-replaced-db-drift 1 "$(ax doctor 2>/dev/null | grep -c 'antigravity-cli conversation_summaries.db: DRIFT')"
eq doctor-keeps-replaced-db replaced-db "$(cat "$app/conversation_summaries.db")"
rm "$app/conversation_summaries.db"
ln -s "$shared/conversation_summaries.db" "$app/conversation_summaries.db"
launch --profile personal >/dev/null
eq cross-account-conversations yes "$([ "$app/conversations" -ef "$DD/profiles/personal/antigravity-cli/conversations" ] && echo yes)"
ln -s "$shared/settings.json" "$app/settings.json"
err private-link launch
rm "$app/settings.json"
(umask 077; printf own > "$app/settings.json")
launch >/dev/null
eq own-settings own "$(cat "$app/settings.json")"
ln -s "$app" "$DD/profiles/alias"
err profile-dir-symlink launch --profile alias
err profile-login-symlink ax profile login alias
rm "$DD/profiles/alias"
# Direct exec + doctor binary check + native log storage guards preserve PID, stdin, exit status and INT/TERM/HUP.
cat > "$T/unmarked-agy" <<'EOF'
#!/bin/sh
printf 'PROFILE=%s\n' "$AGYX_PROFILE"
exit "${FAKE_STATUS:-0}"
EOF
chmod +x "$T/unmarked-agy"
(AGYX_REAL_AGY="$T/unmarked-agy" FAKE_STATUS=7 launch -p hello >"$T/out" 2>"$T/err"); rc=$?
eq storage-unmarked-status 7 "$rc"
eq storage-unmarked-stdout 1 "$(grep -c '^PROFILE=work$' "$T/out")"
eq storage-no-verified-file no "$([ -e "$DD/.verified" ] && echo yes || echo no)"
(AGYX_REAL_AGY="$T/unmarked-agy" ax doctor >/dev/null 2>"$T/err")
eq doctor-unmarked-binary-warning 1 "$(grep -c 'WARNING: file-based token storage markers NOT confirmed' "$T/err")"
eq storage-warning-risk 1 "$(grep -c 'keychain fallback can mix accounts and delete the profile token file' "$T/err")"
(FAKE_STORAGE=keychain launch >/dev/null 2>"$T/err"); rc=$?
eq storage-keychain-first-exit 0 "$rc"
# Next launch sees the previous non-empty bad native log and warns before exec.
launch mcp list >/dev/null 2>"$T/err"
eq storage-recent-log-warning 1 "$(grep -c 'WARNING: file-based token storage NOT confirmed' "$T/err")"
launch >/dev/null 2>"$T/err"
launch >/dev/null 2>"$T/err"
eq storage-wsl-clears-warning '' "$(cat "$T/err")"
(FAKE_LOGIN=1 FAKE_STORAGE=keychain ax profile login badstore >/dev/null 2>"$T/err")
eq storage-login-immediate-warning 1 "$(grep -c 'WARNING: file-based token storage NOT confirmed' "$T/err")"
eq storage-login-temp-cleaned 0 "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'agyx-login-*' 2>/dev/null | wc -l | tr -d ' ')"
rm -rf "$DD/profiles/badstore"
eq storage-stdin 'stdin preserved' "$(printf 'stdin preserved\n' | FAKE_RUN='IFS= read -r line; printf "%s" "$line"' launch)"
# Direct exec means no wrapper shell sits above agy, and INT/TERM/HUP all arrive with default dispositions intact.
FAKE_RUN='printf %s "$$" > "$T/child-pid"' T=$T "$here/bin/agy" >/dev/null &
spawned_pid=$!
wait "$spawned_pid"
eq exec-direct-pid "$spawned_pid" "$(cat "$T/child-pid")"
export READY=$T/guard-ready
sig_shell=/bin/sh
command -v bash >/dev/null 2>&1 && sig_shell=bash
for sig in INT TERM HUP; do
  rm -f "$READY"
  rc=$(
    "$sig_shell" -c '
      set -m
      FAKE_RUN="trap \"exit 23\" INT TERM HUP; : > \"\$READY\"; sleep 2; exit 24" "$1/bin/agy" >/dev/null 2>"$2/err" &
      guard_pid=$!
      i=0
      while [ ! -f "$READY" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
      kill -"$3" "$guard_pid"
      wait "$guard_pid" 2>/dev/null; printf %s "$?"
    ' _ "$here" "$T" "$sig"
  )
  eq "exec-$sig-status" 23 "$rc"
  eq "exec-$sig-no-warning" '' "$(cat "$T/err")"
done
# Newest log only: an older positive marker cannot hide a new keychain fallback.
mkdir -p "$app/log"
printf 'Using file-based token storage because WSL environment detected\n' > "$app/log/guard-old.log"
sleep 1
printf 'Using keychain token storage\n' > "$app/log/guard-new.log"
ax doctor >/dev/null 2>"$T/err"
eq doctor-storage-newest 1 "$(grep -c 'NOT confirmed in .*work/antigravity-cli/log/guard-new.log' "$T/err")"
printf 'Using file-based token storage because SSH environment detected\n' >> "$app/log/guard-new.log"
ax doctor >/dev/null 2>"$T/err"
eq doctor-storage-confirmed 0 "$(grep -c 'NOT confirmed in .*work/antigravity-cli/log/' "$T/err")"
# Token existence only; no parser needed, email comes from own launch log.
(FAKE_LOGIN=1 ax profile login new >/dev/null)
eq login-default-unchanged work "$(cat "$DD/default")"
eq login-email own@example.com "$(cat "$DD/profiles/new/email")"
eq token-mode 600 "$(mode_of "$DD/profiles/new/antigravity-cli/antigravity-oauth-token")"
eq profile-mode 700 "$(mode_of "$DD/profiles/new")"
eq profile-app-mode 700 "$(mode_of "$DD/profiles/new/antigravity-cli")"
chmod 750 "$DD/profiles/new"
chmod 705 "$DD/profiles/new/antigravity-cli"
out=$(ax doctor 2>/dev/null)
eq doctor-profile-permissions 1 "$(printf '%s\n' "$out" | grep -c "permissions: WARNING $DD/profiles/new mode 750")"
eq doctor-app-permissions 1 "$(printf '%s\n' "$out" | grep -c "permissions: WARNING $DD/profiles/new/antigravity-cli mode 705")"
chmod 700 "$DD/profiles/new" "$DD/profiles/new/antigravity-cli"
eq doctor-private-dirs-clean 0 "$(ax doctor 2>/dev/null | grep -c "permissions: WARNING $DD/profiles/new")"
eq list-login 1 "$(ax profile list | grep -c '^new .*own@example.com')"
rm "$DD/default"
(FAKE_LOGIN=1 ax profile login next >/dev/null)
eq first-default next "$(cat "$DD/default")"
eq duplicate-warning 1 "$(ax profile list | grep -c '^WARNING: profiles')"
(FAKE_LOGIN=1 FAKE_EMAIL='' ax profile login next >/dev/null 2>&1)
eq no-stale-login-email 1 "$(ax profile list | grep -c '^next .*logged in, email unknown')"
eq stale-email 1 "$(ax profile list | grep -c '^personal .*not logged in')"
# agyx setup t3code requires an existing valid settings.json, then upserts providers.
t3=$RH/.t3/userdata/settings.json
mkdir -p "$RH/.t3/userdata"
entry=$(cd "$DD" && pwd -P)/agy
err t3code-missing-settings env HOME="$RH" AGYX_DATA_DIR="$DD" AGYX_ASSUME_YES=1 "$here/bin/agyx" setup t3code -y
printf 'not-json\n' > "$t3"
err t3code-invalid-json env HOME="$RH" AGYX_DATA_DIR="$DD" AGYX_ASSUME_YES=1 "$here/bin/agyx" setup t3code -y
printf '%s\n' "{\"keep\":true,\"providerInstances\":{\"codex_x\":{\"driver\":\"codex\"},\"agy_stale\":{\"driver\":\"antigravity\",\"environment\":[{\"name\":\"AGYX_PROFILE\",\"value\":\"gone\"}],\"config\":{\"binaryPath\":\"$entry\"}}}}" > "$t3"
(AGYX_ASSUME_YES=1 ax setup t3code -y >/dev/null)
eq t3code-kept-foreign 1 "$(python3 -c "import json; d=json.load(open('$t3')); print(1 if d.get('keep') and 'codex_x' in d['providerInstances'] else 0)")"
eq t3code-removed-stale 1 "$(python3 -c "import json; d=json.load(open('$t3')); print(0 if 'agy_stale' in d['providerInstances'] else 1)")"
eq t3code-upsert-work 1 "$(python3 -c "import json; i=json.load(open('$t3'))['providerInstances']['agy_work']; print(1 if i['config']['binaryPath']=='$entry' and i['environment'][0]['value']=='work' else 0)")"
eq t3code-upsert-next 1 "$(python3 -c "import json; print(1 if 'agy_next' in json.load(open('$t3'))['providerInstances'] else 0)")"
err t3code-no-tty env HOME="$RH" AGYX_DATA_DIR="$DD" "$here/bin/agyx" setup t3code
printf 'y\n' > "$T/t3-yes"
(AGYX_TTY=$T/t3-yes ax setup t3code >/dev/null)
eq t3code-interactive-yes 1 "$(python3 -c "import json; print(1 if 'agy_work' in json.load(open('$t3'))['providerInstances'] else 0)")"
printf 'n\n' > "$T/t3-no"
before_sum=$(cksum < "$t3")
err t3code-interactive-no env HOME="$RH" AGYX_DATA_DIR="$DD" AGYX_TTY=$T/t3-no "$here/bin/agyx" setup t3code
eq t3code-cancelled-unchanged "$before_sum" "$(cksum < "$t3")"
err t3code-args ax setup t3code extra
err t3code-yes-and-extra ax setup t3code -y extra
err setup-missing ax setup
err setup-unknown ax setup other
# Doctor never reads token contents (deliberately not JSON), reports modes, drift and logs.
printf collision-shared > "$shared/collision"
printf collision-profile > "$app/collision"
(umask 022; printf invalid-json > "$app/antigravity-oauth-token")
ln -s "$shared/missing" "$app/broken"
out=$(FAKE_KEYCHAIN_ITEM=1 ax doctor)
eq doctor-mode 1 "$(printf '%s\n' "$out" | grep -c '^profile mode: real HOME; WSL_INTEROP=agyx')"
eq doctor-permissions 1 "$(printf '%s\n' "$out" | grep -c 'token: WARNING mode 644')"
eq doctor-drift 1 "$(printf '%s\n' "$out" | grep -c 'antigravity-cli collision: DRIFT')"
eq doctor-link 1 "$(printf '%s\n' "$out" | grep -c 'antigravity-cli broken: WARNING')"
eq doctor-keychain-info 1 "$(printf '%s\n' "$out" | grep -c '^keychain: INFO plain agy')"
eq doctor-no-secret 0 "$(grep -Ec ' -[wg]( |$)' "$SECLOG")"
eq doctor-no-token-content 0 "$(printf '%s\n' "$out" | grep -c invalid-json)"
rm "$app/collision"
# Fresh profiles share every known entry before either fake native process writes.
fr=$T/shared-repair frhome=$T/shared-repair/home frdata=$T/shared-repair/data
mkdir -p "$frhome" "$frdata/profiles/one/antigravity-cli" "$frdata/profiles/two/antigravity-cli"
fresh_run() { env HOME="$frhome" AGYX_DATA_DIR="$frdata" AGYX_TRASH_DIR="$fr/trash" "$@"; }
one=$frdata/profiles/one/antigravity-cli two=$frdata/profiles/two/antigravity-cli fs=$frhome/.gemini/antigravity-cli
fresh_run FAKE_RUN='[ -L "$FAKE_APP/conversations" ] && printf first > "$FAKE_APP/conversations/first"' "$here/bin/agy" --profile one >/dev/null
eq first-profile-linked-before-write first "$(cat "$fs/conversations/first")"
fresh_run FAKE_RUN='[ -f "$FAKE_APP/conversations/first" ] && printf second > "$FAKE_APP/conversations/second"' "$here/bin/agy" --profile two >/dev/null
eq second-profile-shares-from-first-launch second "$(cat "$one/conversations/second")"
for e in $(. "$here/runtime/sync.sh"; agyx_shared_entries dirs; agyx_shared_entries files); do
  eq "fresh-both-$e" yes "$([ "$one/$e" -ef "$two/$e" ] && [ -L "$one/$e" ] && [ -L "$two/$e" ] && echo yes)"
done
eq fresh-history-empty 0 "$(wc -c < "$fs/history.jsonl" | tr -d ' ')"
eq fresh-id-valid 1 "$(grep -Ec '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$' "$fs/installation_id")"
for e in antigravity-oauth-token settings.json jetski_state.pbtxt jetbox_summaries_proto.pb; do
  (umask 077; printf dummy-private > "$one/$e")
done
private_stat=$(stamp_of "$one/antigravity-oauth-token" "$one/settings.json" "$one/jetski_state.pbtxt" "$one/jetbox_summaries_proto.pb")
# Build real drift with recursive, hidden, spaced and differently-typed conflicts.
rm "$one/conversations" "$one/brain" "$one/history.jsonl" "$one/conversation_summaries.db" "$one/installation_id"
mkdir -p "$one/conversations/nested" "$fs/conversations/nested" "$one/brain" "$one/conversations/type-clash"
printf profile-newer > "$one/conversations/nested/newer file"
printf shared-older > "$fs/conversations/nested/newer file"
printf profile-older > "$one/conversations/nested/older"
printf shared-newer > "$fs/conversations/nested/older"
printf shared-type > "$fs/conversations/type-clash"
printf hidden > "$one/conversations/.hidden"
printf profile-only > "$one/conversations/only"
ln -s "$fr/outside-target" "$one/conversations/dangling-link"
printf shared-tie > "$fs/conversations/tie"
printf profile-tie > "$one/conversations/tie"
touch -t 202001010000 "$fs/conversations/nested/newer file" "$one/conversations/nested/older"
touch -t 202101010000 "$one/conversations/nested/newer file" "$fs/conversations/nested/older"
touch -t 202201010000 "$one/conversations/type-clash"
touch -t 202001010000 "$fs/conversations/type-clash" "$fs/conversations/tie" "$one/conversations/tie"
printf 'common\nshared-last' > "$fs/history.jsonl"
printf 'common\nprofile-only\nprofile-only\n' > "$one/history.jsonl"
printf shared-db > "$fs/conversation_summaries.db"
printf profile-db > "$one/conversation_summaries.db"
printf profile-wal > "$one/conversation_summaries.db-wal"
printf shared-id > "$fs/installation_id"
printf profile-id > "$one/installation_id"
printf 'n\n' > "$fr/no"; printf 'y\n' > "$fr/yes"
err drift-no-tty fresh_run "$here/bin/agy" --profile one
eq drift-no-tty-kept profile-only "$(cat "$one/conversations/only")"
eq drift-no-tty-no-trash no "$([ -e "$fr/trash" ] && echo yes || echo no)"
eq drift-doctor-still-reports 1 "$(fresh_run "$here/bin/agyx" doctor 2>/dev/null | grep -c 'antigravity-cli conversations: DRIFT')"
eq drift-doctor-no-repair profile-only "$(cat "$one/conversations/only")"
err drift-declined fresh_run AGYX_TTY="$fr/no" "$here/bin/agy" --profile one
eq drift-declined-kept profile-db "$(cat "$one/conversation_summaries.db")"
# A running native writer prevents repair even when consent is supplied.
cat > "$fr/writer with spaces" <<'EOF'
#!/bin/sh
sleep 10 & child=$!
trap 'kill "$child"; wait "$child" 2>/dev/null; exit' TERM
exec 9< "$2"
: > "$1"
wait "$child"
EOF
chmod +x "$fr/writer with spaces"
"$fr/writer with spaces" "$fr/ready" "$fs/conversation_summaries.db" & writer=$!
i=0; while [ ! -f "$fr/ready" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
err drift-busy fresh_run AGYX_REAL_AGY="$fr/writer with spaces" AGYX_ASSUME_YES=1 "$here/bin/agy" --profile one
eq drift-busy-diagnostic 1 "$(grep -c 'close agy before shared repair' "$T/err")"
kill "$writer"; wait "$writer" 2>/dev/null
eq drift-busy-kept profile-db "$(cat "$one/conversation_summaries.db")"
fresh_run AGYX_TTY="$fr/yes" "$here/bin/agy" --profile two > "$fr/out" 2> "$fr/err"; rc=$?
eq drift-repair-success 0 "$rc"
eq drift-one-prompt 1 "$(grep -c 'Continue?' "$fr/err")"
trash=$(find "$fr/trash" -type d -name 'agyx-shared-repair-*')
eq repair-profile-newer profile-newer "$(cat "$fs/conversations/nested/newer file")"
eq repair-shared-older-trashed shared-older "$(cat "$trash/one/conversations/nested/newer file")"
eq repair-shared-newer shared-newer "$(cat "$fs/conversations/nested/older")"
eq repair-profile-older-trashed profile-older "$(cat "$trash/one/conversations/nested/older")"
eq repair-tie-shared shared-tie "$(cat "$fs/conversations/tie")"
eq repair-tie-profile-trashed profile-tie "$(cat "$trash/one/conversations/tie")"
eq repair-type-newer directory "$([ -d "$fs/conversations/type-clash" ] && echo directory)"
eq repair-type-loser-trashed shared-type "$(cat "$trash/one/conversations/type-clash")"
eq repair-hidden hidden "$(cat "$fs/conversations/.hidden")"
eq repair-unique profile-only "$(cat "$fs/conversations/only")"
eq repair-nested-link-not-followed "$fr/outside-target" "$(readlink "$fs/conversations/dangling-link")"
eq repair-nested-link-target-untouched no "$([ -e "$fr/outside-target" ] && echo yes || echo no)"
eq repair-history 'common shared-last profile-only ' "$(tr '\n' ' ' < "$fs/history.jsonl")"
eq repair-history-original 'common profile-only profile-only ' "$(tr '\n' ' ' < "$trash/one/history.jsonl")"
eq repair-db-shared-kept shared-db "$(cat "$fs/conversation_summaries.db")"
eq repair-db-trashed profile-db "$(cat "$trash/one/conversation_summaries.db")"
eq repair-db-wal-trashed profile-wal "$(cat "$trash/one/conversation_summaries.db-wal")"
eq repair-id-shared-kept shared-id "$(cat "$fs/installation_id")"
eq repair-id-trashed profile-id "$(cat "$trash/one/installation_id")"
eq repair-private-stat-unchanged "$private_stat" "$(stamp_of "$one/antigravity-oauth-token" "$one/settings.json" "$one/jetski_state.pbtxt" "$one/jetbox_summaries_proto.pb")"
for e in conversations brain history.jsonl conversation_summaries.db installation_id; do
  eq "repair-link-$e" "$fs/$e" "$(readlink "$one/$e")"
done
fresh_run "$here/bin/agy" --profile one >/dev/null 2> "$fr/err"
eq repair-idempotent '' "$(cat "$fr/err")"
eq repair-idempotent-history 3 "$(wc -l < "$fs/history.jsonl" | tr -d ' ')"
eq repair-idempotent-trash-count 1 "$(find "$fr/trash" -type d -name 'agyx-shared-repair-*' | wc -l | tr -d ' ')"
eq repair-doctor-clean 0 "$(fresh_run "$here/bin/agyx" doctor 2>/dev/null | grep -c DRIFT)"
# Empty shared history and two unadopted copies also repair without duplicate lines.
rm "$two/history.jsonl"
printf 'only-line\nonly-line\n' > "$two/history.jsonl"
: > "$fs/history.jsonl"
mkdir "$one/future-shared" "$two/future-shared"
printf one > "$one/future-shared/one"
printf two > "$two/future-shared/two"
fresh_run AGYX_ASSUME_YES=1 "$here/bin/agy" --profile two >/dev/null 2> "$fr/err"; rc=$?
eq repair-assume-yes 0 "$rc"
eq repair-assume-no-prompt 0 "$(grep -c 'Continue?' "$fr/err")"
eq repair-empty-shared-history only-line "$(cat "$fs/history.jsonl")"
eq repair-unadopted-pair one,two "$(cat "$fs/future-shared/one"),$(cat "$fs/future-shared/two")"
eq repair-unadopted-links yes "$([ -L "$one/future-shared" ] && [ "$one/future-shared" -ef "$two/future-shared" ] && echo yes)"
# Adopt an older profile's sole known entry before creating an empty shared target.
rm "$one/brain" "$two/brain"; rmdir "$fs/brain"
mkdir "$one/brain"; printf prior > "$one/brain/prior"
fresh_run AGYX_ASSUME_YES=1 "$here/bin/agy" --profile two >/dev/null 2> "$fr/err"
eq seed-preserves-older-profile prior "$(cat "$fs/brain/prior")"
eq seed-links-older-profile "$fs/brain" "$(readlink "$one/brain")"
# Adopting an old DB keeps its WAL together and never overwrites an orphan shared WAL.
rm "$one/conversation_summaries.db" "$two/conversation_summaries.db" "$fs/conversation_summaries.db"
printf adopted-db > "$one/conversation_summaries.db"
printf adopted-wal > "$one/conversation_summaries.db-wal"
printf orphan-wal > "$fs/conversation_summaries.db-wal"
err repair-orphan-sidecar fresh_run AGYX_ASSUME_YES=1 "$here/bin/agy" --profile two
eq repair-orphan-source-intact adopted-db "$(cat "$one/conversation_summaries.db")"
eq repair-orphan-target-intact orphan-wal "$(cat "$fs/conversation_summaries.db-wal")"
rm "$fs/conversation_summaries.db-wal"
fresh_run AGYX_ASSUME_YES=1 "$here/bin/agy" --profile two >/dev/null 2> "$fr/err"; rc=$?
eq repair-adopt-db 0 "$rc"
eq repair-adopt-db-value adopted-db "$(cat "$fs/conversation_summaries.db")"
eq repair-adopt-db-wal adopted-wal "$(cat "$fs/conversation_summaries.db-wal")"
eq repair-adopt-db-link "$fs/conversation_summaries.db" "$(readlink "$one/conversation_summaries.db")"
rm "$fs/conversation_summaries.db"
err seed-orphan-sidecar fresh_run "$here/bin/agy" --profile two
eq seed-orphan-sidecar-preserved adopted-wal "$(cat "$fs/conversation_summaries.db-wal")"
eq seed-orphan-no-fake-db no "$([ -e "$fs/conversation_summaries.db" ] && echo yes || echo no)"
printf adopted-db > "$fs/conversation_summaries.db"
# Repair refusal before shared dir exists creates neither ~/.gemini nor the prepare lock.
mkdir -p "$T/preconsent/home" "$T/preconsent/data/profiles/p/antigravity-cli/brain"
err repair-refusal-no-shared-dir env HOME="$T/preconsent/home" AGYX_DATA_DIR="$T/preconsent/data" AGYX_TTY="$fr/no" "$here/bin/agy" --profile p
eq repair-refusal-zero-gemini absent "$([ -e "$T/preconsent/home/.gemini" ] && echo present || echo absent)"
# Concurrent preparers wait for an active preparation, and still fail if a stale lock remains.
mkdir "$frdata/.lock"
err prepare-lock-busy fresh_run AGYX_LOCK_TRIES=2 "$here/bin/agy" --profile one
(sleep 0.15; rmdir "$frdata/.lock") &
wait_pid=$!
fresh_run "$here/bin/agy" --profile one >/dev/null 2>"$fr/err"; rc=$?
wait "$wait_pid"
eq prepare-lock-waits 0 "$rc"
p1='' p2='' p3=''
fresh_run "$here/bin/agy" --profile one >/dev/null 2>"$fr/c1" & p1=$!
fresh_run "$here/bin/agy" --profile two >/dev/null 2>"$fr/c2" & p2=$!
fresh_run "$here/bin/agy" --profile one >/dev/null 2>"$fr/c3" & p3=$!
rc1=0 rc2=0 rc3=0
wait "$p1" || rc1=$?; wait "$p2" || rc2=$?; wait "$p3" || rc3=$?
eq prepare-concurrent-burst "0:0:0" "$rc1:$rc2:$rc3"
# First-run gate: read-only commands and refusal leave disk alone.
fresh=$T/fresh
for command in '--help' '--version' 'profile list' 'profile default' doctor; do
  # shellcheck disable=SC2086 # fixed command words above
  (AGYX_DATA_DIR=$fresh ax $command >/dev/null)
  eq "readonly-$command" absent "$([ -e "$fresh" ] && echo present || echo absent)"
done
err first-nonterminal env AGYX_DATA_DIR="$fresh" "$here/bin/agyx" profile login p
printf 'n\n' > "$T/no"
err first-no env AGYX_DATA_DIR="$fresh" AGYX_TTY="$T/no" "$here/bin/agyx" profile login p
printf 'y\n' > "$T/yes"
(AGYX_DATA_DIR=$fresh AGYX_TTY=$T/yes ax profile login p >/dev/null 2>"$T/err")
eq first-yes present "$([ -d "$fresh/profiles/p/antigravity-cli" ] && echo present)"
eq no-whitelist absent "$([ -e "$RH/.config/agyx/symlinks" ] && echo present || echo absent)"
# Uninstall fixture + shared native-agy token (agyx never touches ~/.gemini).
udata=$T/uninstall-data
mkdir -p "$udata/profiles/old/antigravity-cli"
printf plain-agy > "$shared/antigravity-oauth-token"
# Uninstall refuses an open profile DB, but never blocks an unrelated plain native agy process.
"$fr/writer with spaces" "$fr/plain-ready" "$T/fake-agy" & plain_writer=$!
i=0; while [ ! -f "$fr/plain-ready" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
mkdir -p "$T/uninst-plain/profiles/p/antigravity-cli"
(AGYX_DATA_DIR=$T/uninst-plain AGYX_ASSUME_YES=1 ax uninstall >/dev/null 2>"$T/err"); rc=$?
eq uninstall-ignores-plain-agy 0 "$rc"
kill "$plain_writer"; wait "$plain_writer" 2>/dev/null
"$fr/writer with spaces" "$fr/uninstall-ready" "$app/conversation_summaries.db" & writer=$!
i=0; while [ ! -f "$fr/uninstall-ready" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
err uninstall-live-profile env AGYX_ASSUME_YES=1 "$here/bin/agyx" uninstall
eq uninstall-live-profile-diagnostic 1 "$(grep -c 'agy is still running' "$T/err")"
eq uninstall-live-profile-preserved yes "$([ -d "$DD/profiles/work" ] && echo yes)"
kill "$writer"; wait "$writer" 2>/dev/null
# Uninstall refusal, then Trash; shared state and plain agy are retained.
err uninstall-no env AGYX_DATA_DIR="$udata" AGYX_TTY="$T/no" "$here/bin/agyx" uninstall
(AGYX_DATA_DIR=$udata AGYX_ASSUME_YES=1 ax uninstall >/dev/null 2>"$T/err")
eq uninstall-data-gone absent "$([ -e "$udata" ] && echo present || echo absent)"
eq uninstall-data-trash 1 "$(find "$AGYX_TRASH_DIR" -path '*/data/profiles/old/antigravity-cli' | wc -l | tr -d ' ')"
eq uninstall-plain-token-kept plain-agy "$(cat "$shared/antigravity-oauth-token")"
eq uninstall-shared-history-kept history "$(cat "$shared/history.jsonl")"
# Existing helpers: stable Homebrew path, stale shim entry repair, non-agyx entry left alone.
rm "$DD/agy"; ln -s "$T/gone/opt/agyx/libexec/bin/agy" "$DD/agy"
launch >/dev/null
eq repaired-entry "$here/bin/agy" "$(readlink "$DD/agy")"
mkdir -p "$T/prefix/Cellar/agyx/0.1.3/bin" "$T/prefix/opt"
printf x > "$T/prefix/Cellar/agyx/0.1.3/bin/agy"
ln -s ../Cellar/agyx/0.1.3 "$T/prefix/opt/agyx"
eq stable-path "$T/prefix/opt/agyx/bin/agy" "$(. "$here/runtime/sync.sh"; agyx_stable "$T/prefix/Cellar/agyx/0.1.3/bin/agy"; echo "$AGYX_STABLE")"
# A Homebrew install of the beta formula agyx-beta behaves like agyx: Cellar paths map to its own
# opt path, and agyx uninstall removes the formula it was installed as.
mkdir -p "$T/binstub"
printf '#!/bin/sh\necho "brew $*" >> "$BREWLOG"\n' > "$T/binstub/brew"
chmod +x "$T/binstub/brew"
export BREWLOG=$T/brew.log
brewtest() { # $1 = Cellar dir (formula/version), $2 = opt name, $3 = formula brew must uninstall
  d=$T/prefix/Cellar/$1
  mkdir -p "$d/libexec/bin" "$d/libexec/runtime" "$T/prefix/opt" "$T/bdata"
  cp "$here/bin/agyx" "$here/bin/agy" "$d/libexec/bin/"
  cp "$here/runtime/"*.sh "$d/libexec/runtime/"
  ln -sfn "../Cellar/$1" "$T/prefix/opt/$2"
  eq "stable-$2-path" "$T/prefix/opt/$2/libexec/bin/agy" "$(. "$here/runtime/sync.sh"; agyx_stable "$d/libexec/bin/agy"; echo "$AGYX_STABLE")"
  (AGYX_DATA_DIR=$T/bdata AGYX_ASSUME_YES=1 PATH="$T/binstub:$PATH" "$d/libexec/bin/agyx" uninstall >/dev/null 2>"$T/err-$2")
  eq "uninstall-$2-formula" "brew uninstall $3" "$(tail -n 1 "$BREWLOG")"
  eq "uninstall-$2-hint" "1" "$(grep -c "(brew uninstall $3)" "$T/err-$2")"
}
: > "$BREWLOG"
brewtest agyx/0.2.0 agyx agyx
brewtest agyx-beta/0.2.0-beta.9 agyx-beta agyx-beta
# Linux/XDG trash base fallback when AGYX_TRASH_DIR is unset and ~/.Trash does not exist.
eq xdg-trash-fallback "$T/xdg-data/Trash/files" "$(unset AGYX_TRASH_DIR; XDG_DATA_HOME=$T/xdg-data R=$T/linux-home; . "$here/runtime/sync.sh"; AGYX_OS=Linux; agyx_trash_base)"
# curl|sh style prefix install: bin+runtime under ~/.local/lib/agyx, PATH link, uninstall removes both.
IP=$T/rh-install
mkdir -p "$IP"
(HOME=$IP sh "$here/scripts/install.sh" --from "$here" --prefix "$IP/.local/lib/agyx" --bin-dir "$IP/.local/bin" >/dev/null)
eq install-prefix-marker "$(sed -n 's/^AGYX_VERSION=\([^ #]*\).*/\1/p' "$here/runtime/sync.sh")" "$(cat "$IP/.local/lib/agyx/.agyx-prefix")"
eq install-prefix-link "$IP/.local/lib/agyx/bin/agyx" "$(readlink "$IP/.local/bin/agyx")"
eq install-prefix-version "agyx $(cat "$IP/.local/lib/agyx/.agyx-prefix")" "$(HOME=$IP "$IP/.local/bin/agyx" --version | head -n 1)"
mkdir -p "$IP/.local/share/agyx/profiles/work/antigravity-cli"
(HOME=$IP AGYX_ASSUME_YES=1 "$IP/.local/bin/agyx" uninstall >/dev/null 2>"$T/err-prefix")
eq uninstall-prefix-program absent "$([ -e "$IP/.local/lib/agyx" ] && echo present || echo absent)"
eq uninstall-prefix-link absent "$([ -e "$IP/.local/bin/agyx" ] && echo present || echo absent)"
eq uninstall-prefix-data-trashed 1 "$(find "$AGYX_TRASH_DIR" -path '*/data/profiles/work/antigravity-cli' | wc -l | tr -d ' ')"
printf 'passed: %s, failed: %s\n' "$pass" "$fail"
[ "$fail" = 0 ]
