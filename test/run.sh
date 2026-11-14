#!/bin/sh
# Offline tests. PATH excludes the real agy; every security call uses a stub.
umask 022
here=$(cd "$(dirname "$0")/.." && pwd -P)
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
export HOME=$T/home AGYX_DATA_DIR=$T/data AGYX_TRASH_DIR=$T/trash
export SECLOG=$T/security.log AGYX_SECURITY=$T/security AGYX_REAL_AGY=$T/fake-agy
unset AGYX_PROFILE AGY_PROFILE AGYX_REAL_HOME WSL_DISTRO_NAME WSL_INTEROP SSH_CLIENT SSH_CONNECTION SSH_TTY ZDOTDIR BASH_ENV
unset AGYX_ASSUME_YES AGYX_TTY AGYX_ORIG_WSL_SET AGYX_ORIG_WSL
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
mkdir -p "$HOME" "$AGYX_DATA_DIR/profiles/work/antigravity-cli" "$AGYX_DATA_DIR/profiles/personal/antigravity-cli" "$AGYX_TRASH_DIR"
RH=$HOME DD=$AGYX_DATA_DIR
cat > "$T/fake-agy" <<'EOF'
#!/bin/sh
app= log=
for a in "$@"; do case $a in --app_data_dir=*) app=${a#*=} ;; esac; done
prev=
for a in "$@"; do
  [ "$prev" != --log-file ] || log=$a
  case $a in --log-file=*) log=${a#*=} ;; esac
  prev=$a
done
if [ -n "$log" ]; then
  case ${FAKE_STORAGE:-WSL} in
    missing) ;;
    keychain) printf 'Using keychain token storage\n' >> "$log" ;;
    *) printf 'Using file-based token storage because %s environment detected\n' "${FAKE_STORAGE:-WSL}" >> "$log" ;;
  esac
fi
[ -z "$app" ] || app=$HOME/.gemini/$app
export FAKE_APP=$app
if [ "${FAKE_LOGIN-}" = 1 ]; then
  (umask 077; printf 'not-a-real-token\n' > "$app/antigravity-oauth-token")
  printf 'applyAuthResult ok email=%s\n' "${FAKE_EMAIL-own@example.com}" >> "$log"
  exit 0
fi
if [ -n "${FAKE_RUN-}" ]; then exec /bin/sh -c "$FAKE_RUN"; fi
printf 'HOME=%s\nPROFILE=%s\nWSL=%s\nSSH_CLIENT=%s\nSSH_CONNECTION=%s\nSSH_TTY=%s\n' "$HOME" "$AGYX_PROFILE" "${WSL_DISTRO_NAME-unset}" "${SSH_CLIENT-unset}" "${SSH_CONNECTION-unset}" "${SSH_TTY-unset}"
for a in "$@"; do printf 'ARG=%s\n' "$a"; done
exit "${FAKE_STATUS:-0}"
EOF
cat > "$T/security" <<'EOF'
#!/bin/sh
printf 'HOME=%s %s\n' "$HOME" "$*" >> "$SECLOG"
case $1 in
  delete-keychain) [ "${FAKE_SEC_FAIL-}" != 1 ] || exit 1; rm "$2" ;;
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
eq wsl-set agyx "$(FIELD=WSL field)"
eq wsl-existing Ubuntu "$(WSL_DISTRO_NAME=Ubuntu FIELD=WSL field)"
eq wsl-empty agyx "$(WSL_DISTRO_NAME='' FIELD=WSL field)"
for bad in Work 1a a/b doctor profile uninstall ''; do err "profile-$bad" launch --profile "$bad"; done
err missing launch --profile
err duplicate launch --profile work --profile personal
err missing-dir launch --profile absent
err env-invalid env AGYX_PROFILE=BAD "$here/bin/agy"
mv "$DD/default" "$T/default"
err no-default launch
mv "$T/default" "$DD/default"
# The app flag precedes all subcommands, even those that skip --log-file.
for cmd in interactive -p acp mcp login logout models agent agents plugins plugin remote-control mic-serve install help changelog update --help -h --version; do
  if [ "$cmd" = interactive ]; then out=$(launch); else out=$(launch "$cmd"); fi
  first=$(printf '%s\n' "$out" | grep '^ARG=' | head -n 1)
  eq "app-first-$cmd" 1 "$(printf '%s\n' "$first" | grep -c '^ARG=--app_data_dir=')"
  case $cmd in help|changelog|mcp|update|--help|-h|--version) want=0 ;; *) want=1 ;; esac
  eq "log-$cmd" "$want" "$(printf '%s\n' "$out" | grep -c '^ARG=--log-file$')"
done
out=$(launch --profile work -- 'hello world' '' --profile personal -- x)
eq argv 'ARG=hello world|ARG=|ARG=--profile|ARG=personal|ARG=--|ARG=x|' "$(printf '%s\n' "$out" | grep '^ARG=' | tail -n 6 | tr '\n' '|')"
eq own-log 1 "$(launch --log-file "$T/own.log" | grep -c '^ARG=--log-file$')"
err override-app launch --app_data_dir=elsewhere
err override-gemini launch --gemini_dir /elsewhere
err override-single-dash launch -app_data_dir=elsewhere
# Log allocation is unique even at a fixed timestamp.
(AGYX_LOG_STAMP=20000101_000000 launch >/dev/null)
(AGYX_LOG_STAMP=20000101_000000 launch >/dev/null)
eq unique-log-names 2 "$(find "$DD/profiles/work/log" -name 'cli-20000101_000000*.log' | wc -l | tr -d ' ')"
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
# Bash/Zsh restore unset/empty/existing WSL and user's startup variables, even nested.
for shell in bash zsh; do
  command -v "$shell" >/dev/null || { echo "SKIP $shell"; continue; }
  snippet="$shell -c 'printf \"%s|%s|%s|%s\" \"\$HOME\" \"\${WSL_DISTRO_NAME-unset}\" \"\${ZDOTDIR-unset}\" \"\${BASH_ENV-unset}\"'"
  eq "$shell-unset" "$RH|unset|unset|unset" "$(FAKE_RUN="$snippet" launch)"
  eq "$shell-empty" "$RH|||" "$(WSL_DISTRO_NAME='' ZDOTDIR='' BASH_ENV='' FAKE_RUN="$snippet" launch)"
  eq "$shell-existing" "$RH|Ubuntu|/zd|/be" "$(WSL_DISTRO_NAME=Ubuntu ZDOTDIR=/zd BASH_ENV=/be FAKE_RUN="$snippet" launch)"
  nested="$shell -c 'FAKE_RUN= \"$here/bin/agy\" --profile personal'"
  eq "$shell-nested" personal "$(FAKE_RUN="$nested" launch | sed -n 's/^PROFILE=//p')"
  nested="$shell -c 'FAKE_RUN= \"$here/bin/agy\"'"
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
printf '[ ! "${AGYX_ORIG_WSL_SET+x}" ] || printf leak >> "$COUNT"\nprintf x >> "$COUNT"\n' > "$T/zd/.zshenv"
printf '[ ! "${AGYX_ORIG_WSL_SET+x}" ] || printf leak >> "$COUNT"\nprintf x >> "$COUNT"\n' > "$T/benv"
export COUNT=$T/count
: > "$COUNT"
(ZDOTDIR=$T/zd FAKE_RUN='zsh -c true' launch >/dev/null)
eq zshenv-once x "$(cat "$COUNT")"
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
# macOS SQLite resolves the DB link before deriving WAL/SHM names and taking locks.
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
for private in antigravity-oauth-token settings.json jetski_state.pbtxt jetbox_summaries_proto.pb; do
  eq "not-shared-$private" no "$([ -e "$app/$private" ] && echo yes || echo no)"
done
printf newly-created > "$app/future-entry"
launch >/dev/null
eq adopted newly-created "$(cat "$shared/future-entry")"
eq adoption-link "$shared/future-entry" "$(readlink "$app/future-entry")"
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
# Storage guard uses only this launch's log and preserves stdout/exit status.
(FAKE_STORAGE=missing FAKE_STATUS=7 launch -p hello >"$T/out" 2>"$T/err"); rc=$?
eq storage-missing-status 7 "$rc"
eq storage-missing-stdout 1 "$(grep -c '^PROFILE=work$' "$T/out")"
eq storage-missing-warning 1 "$(grep -c 'WARNING: file-based token storage NOT confirmed' "$T/err")"
eq storage-warning-risk 1 "$(grep -c 'keychain fallback can mix accounts and delete the profile token file' "$T/err")"
(FAKE_STORAGE=keychain launch >/dev/null 2>"$T/err"); rc=$?
eq storage-keychain-decision-warning '0,1' "$rc,$(grep -c 'WARNING: file-based token storage NOT confirmed' "$T/err")"
(FAKE_STORAGE=SSH FAKE_STATUS=8 launch -p hello >/dev/null 2>"$T/err"); rc=$?
eq storage-ssh-status 8 "$rc"
eq storage-ssh-no-warning '' "$(cat "$T/err")"
launch >/dev/null 2>"$T/err"
eq storage-wsl-no-warning '' "$(cat "$T/err")"
for option in split equals; do
  if [ "$option" = split ]; then set -- --log-file "$T/caller-$option.log"
  else set -- "--log-file=$T/caller-$option.log"; fi
  (FAKE_STORAGE=missing launch "$@" >/dev/null 2>"$T/err")
  eq "storage-caller-$option" 1 "$(grep -c "NOT confirmed in $T/caller-$option.log" "$T/err")"
done
(cd "$T" && FAKE_STORAGE=missing launch --log-file=- >/dev/null 2>"$T/err")
eq storage-dash-log-is-file 1 "$(grep -c 'NOT confirmed in -' "$T/err")"
eq storage-stdin 'stdin preserved' "$(printf 'stdin preserved\n' | FAKE_RUN='IFS= read -r line; printf "%s" "$line"' launch)"
# TERM sent to the shim PID must reach agy; waiting must retain the child's status.
export READY=$T/guard-ready
for sig in TERM HUP; do
  rm -f "$READY"
  FAKE_RUN='trap "exit 23" TERM HUP; : > "$READY"; sleep 1; exit 24' "$here/bin/agy" >/dev/null 2>"$T/err" &
  guard_pid=$!
  i=0
  while [ ! -f "$READY" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  kill -"$sig" "$guard_pid"
  wait "$guard_pid"; rc=$?
  eq "storage-$sig-forward-status" 23 "$rc"
  eq "storage-$sig-no-warning" '' "$(cat "$T/err")"
done
# A skipped/no-log invocation must not inspect an older bad log.
(FAKE_STORAGE=missing launch mcp list >/dev/null 2>"$T/err")
eq storage-no-log-no-warning '' "$(cat "$T/err")"
# Newest log only: an older positive marker cannot hide a new keychain fallback.
printf 'Using file-based token storage because WSL environment detected\n' > "$app/../log/guard-old.log"
sleep 1
printf 'Using keychain token storage\n' > "$app/../log/guard-new.log"
ax doctor >/dev/null 2>"$T/err"
eq doctor-storage-newest 1 "$(grep -c 'NOT confirmed in .*work/log/guard-new.log' "$T/err")"
printf 'Using file-based token storage because SSH environment detected\n' >> "$app/../log/guard-new.log"
ax doctor >/dev/null 2>"$T/err"
eq doctor-storage-confirmed 0 "$(grep -c 'NOT confirmed in .*work/log/' "$T/err")"
# Token existence only; no parser needed, email comes from own launch log.
(FAKE_LOGIN=1 ax profile login new >/dev/null)
eq login-default-unchanged work "$(cat "$DD/default")"
eq login-email own@example.com "$(cat "$DD/profiles/new/email")"
eq token-mode 600 "$(stat -f %Lp "$DD/profiles/new/antigravity-cli/antigravity-oauth-token")"
eq profile-mode 700 "$(stat -f %Lp "$DD/profiles/new")"
eq profile-app-mode 700 "$(stat -f %Lp "$DD/profiles/new/antigravity-cli")"
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
# Doctor never reads token contents (deliberately not JSON), reports modes, drift and logs.
printf collision-shared > "$shared/collision"
printf collision-profile > "$app/collision"
(umask 022; printf invalid-json > "$app/antigravity-oauth-token")
ln -s "$shared/missing" "$app/broken"
out=$(FAKE_KEYCHAIN_ITEM=1 ax doctor)
eq doctor-mode 1 "$(printf '%s\n' "$out" | grep -c '^profile mode: real HOME; WSL_DISTRO_NAME=agyx; --app_data_dir=')"
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
private_stat=$(stat -f '%i:%p:%m:%z' "$one/antigravity-oauth-token" "$one/settings.json" "$one/jetski_state.pbtxt" "$one/jetbox_summaries_proto.pb")
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
eq repair-private-stat-unchanged "$private_stat" "$(stat -f '%i:%p:%m:%z' "$one/antigravity-oauth-token" "$one/settings.json" "$one/jetski_state.pbtxt" "$one/jetbox_summaries_proto.pb")"
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
# Concurrent preparers cannot mutate a repair in progress.
mkdir "$frhome/.gemini/.agyx-shared-prepare-lock"
err prepare-lock-busy fresh_run "$here/bin/agy" --profile one
rmdir "$frhome/.gemini/.agyx-shared-prepare-lock"
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
# Legacy migration: refusal changes nothing, then one consent covers all profiles.
legacy=$T/legacy
for p in old oldtwo; do
  mkdir -p "$legacy/profiles/$p/home/Library/Keychains" "$legacy/profiles/$p/log"
  printf keychain > "$legacy/profiles/$p/home/Library/Keychains/login.keychain-db"
  printf kept > "$legacy/profiles/$p/log/old.log"
  printf old@example.com > "$legacy/profiles/$p/email"
done
mkdir -p "$RH/.config/agyx"
printf whitelist > "$RH/.config/agyx/symlinks"
# Replace only our fixture's default token file, never a real user's file.
rm "$shared/antigravity-oauth-token"
mkdir "$shared/antigravity-oauth-token"
cat > "$shared/antigravity-oauth-token/README" <<'EOF'
agyx keeps this directory here so the Antigravity CLI (agy) cannot write a token file at this path:
all agyx profiles share this ~/.gemini, so such a file would be shared by every Google account.
Logins live only in each profile's own keychain. Delete this directory only after uninstalling agyx.
EOF
: > "$SECLOG"
err migration-no-tty env AGYX_DATA_DIR="$legacy" "$here/bin/agyx" profile list
err migration-no env AGYX_DATA_DIR="$legacy" AGYX_TTY="$T/no" "$here/bin/agyx" profile list
eq migration-no-writes '' "$(cat "$SECLOG")"
(AGYX_DATA_DIR=$legacy AGYX_TTY=$T/yes ax profile list > "$T/list" 2> "$T/err")
eq migration-all 2 "$(grep -c 'not logged in' "$T/list")"
eq migration-prompt-once 1 "$(grep -c 'Continue?' "$T/err")"
eq migration-keychains 2 "$(grep -c 'delete-keychain' "$SECLOG")"
eq migration-explicit-home 2 "$(grep -c "^HOME=$legacy/profiles/.*home delete-keychain $legacy/profiles/.*home/Library/Keychains/login.keychain-db$" "$SECLOG")"
eq migration-home-gone absent "$([ -d "$legacy/profiles/old/home" ] && echo present || echo absent)"
eq migration-email-kept old@example.com "$(cat "$legacy/profiles/old/email")"
eq migration-log-kept kept "$(cat "$legacy/profiles/old/log/old.log")"
eq migration-app-mode 700 "$(stat -f %Lp "$legacy/profiles/old/antigravity-cli")"
eq migration-trash 2 "$(find "$AGYX_TRASH_DIR" -name home -type d | wc -l | tr -d ' ')"
eq migration-blocker-removed absent "$([ -e "$shared/antigravity-oauth-token" ] && echo present || echo absent)"
eq migration-whitelist-removed absent "$([ -e "$RH/.config/agyx/symlinks" ] && echo present || echo absent)"
eq migration-whitelist-trashed whitelist "$(cat "$(find "$AGYX_TRASH_DIR" -type f -name symlinks)")"
(AGYX_DATA_DIR=$legacy ax profile list >/dev/null)
eq migration-idempotent 2 "$(grep -c delete-keychain "$SECLOG")"
# A failed keychain deletion must stop, not silently abandon the login in the Trash.
mkdir -p "$legacy/profiles/fail/home/Library/Keychains"
printf fail > "$legacy/profiles/fail/home/Library/Keychains/login.keychain-db"
err migration-failure env AGYX_DATA_DIR="$legacy" AGYX_ASSUME_YES=1 FAKE_SEC_FAIL=1 "$here/bin/agyx" profile list
eq migration-failure-kept present "$([ -d "$legacy/profiles/fail/home" ] && echo present)"
(AGYX_DATA_DIR=$legacy AGYX_ASSUME_YES=1 ax profile list >/dev/null 2>&1)
# Unknown blocker dirs and a plain-agy token are never removed/read.
mkdir "$shared/antigravity-oauth-token"
printf unknown > "$shared/antigravity-oauth-token/README"
( . "$here/runtime/sync.sh"; R=$RH; agyx_remove_blocker )
eq unknown-blocker-kept unknown "$(cat "$shared/antigravity-oauth-token/README")"
rm "$shared/antigravity-oauth-token/README"; rmdir "$shared/antigravity-oauth-token"
printf plain-agy > "$shared/antigravity-oauth-token"
# Uninstall refusal, then Trash; shared state and plain agy are retained.
err uninstall-no env AGYX_DATA_DIR="$legacy" AGYX_TTY="$T/no" "$here/bin/agyx" uninstall
(AGYX_DATA_DIR=$legacy AGYX_ASSUME_YES=1 ax uninstall >/dev/null 2>"$T/err")
eq uninstall-data-gone absent "$([ -e "$legacy" ] && echo present || echo absent)"
eq uninstall-data-trash 1 "$(find "$AGYX_TRASH_DIR" -path '*/data/profiles/old/antigravity-cli' | wc -l | tr -d ' ')"
eq uninstall-plain-token-kept plain-agy "$(cat "$shared/antigravity-oauth-token")"
eq uninstall-shared-history-kept history "$(cat "$shared/history.jsonl")"
# Existing helpers: stable Homebrew path, stale shim entry repair, non-agyx entry left alone.
rm "$DD/bin/agy"; ln -s /missing/agy "$DD/bin/agy"
launch >/dev/null
eq repaired-entry "$here/bin/agy" "$(readlink "$DD/bin/agy")"
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
  cp "$here/runtime/sync.sh" "$d/libexec/runtime/"
  ln -sfn "../Cellar/$1" "$T/prefix/opt/$2"
  eq "stable-$2-path" "$T/prefix/opt/$2/libexec/bin/agy" "$(. "$here/runtime/sync.sh"; agyx_stable "$d/libexec/bin/agy"; echo "$AGYX_STABLE")"
  (AGYX_DATA_DIR=$T/bdata AGYX_ASSUME_YES=1 PATH="$T/binstub:$PATH" "$d/libexec/bin/agyx" uninstall >/dev/null 2>"$T/err-$2")
  eq "uninstall-$2-formula" "brew uninstall $3" "$(tail -n 1 "$BREWLOG")"
  eq "uninstall-$2-hint" "1" "$(grep -c "(brew uninstall $3)" "$T/err-$2")"
}
: > "$BREWLOG"
brewtest agyx/0.1.3 agyx agyx
brewtest agyx-beta/0.2.0-beta.1 agyx-beta agyx-beta
printf 'passed: %s, failed: %s\n' "$pass" "$fail"
[ "$fail" = 0 ]
