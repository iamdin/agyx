#!/bin/sh
# shellcheck disable=SC3013 # -ef/-nt are POSIX.1-2024 ( omitted only in older ShellCheck < 0.10 )
# Offline tests. PATH excludes the real agy; every security call uses a stub.
umask 022
for _v in $(env | sed -n 's/^\(AGY[X_][A-Za-z0-9_]*\)=.*/\1/p'); do unset "$_v"; done
unset AGY_PROFILE WSL_DISTRO_NAME WSL_INTEROP SSH_CLIENT SSH_CONNECTION SSH_TTY ZDOTDIR BASH_ENV XDG_CONFIG_HOME XDG_DATA_HOME XDG_RUNTIME_DIR
here=$(cd "$(dirname "$0")/.." && pwd -P)
only_suite=''
if [ "${1-}" = --suite ] && [ $# -eq 2 ]; then only_suite=$2; fi

T=$(mktemp -d) || exit 1
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT
export AGYX_SECURITY=$T/security AGYX_REAL_AGY=$T/fake-agy AGYX_DOCKERENV=$T/no-docker DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/fake-bus
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

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
cat > "$T/writer with spaces" <<'EOF'
#!/bin/sh
sleep 10 & child=$!
trap 'kill "$child"; wait "$child" 2>/dev/null; exit' TERM
exec 9< "$2"
: > "$1"
wait "$child"
EOF
chmod +x "$T/fake-agy" "$T/security" "$T/writer with spaces"

ax() { "$here/bin/agyx" "$@"; }
launch() { "$here/bin/agy" "$@"; }
mode_of() { if [ "$(uname -s)" = Darwin ]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi; }
stamp_of() { if [ "$(uname -s)" = Darwin ]; then stat -f '%i:%p:%m:%z' "$@"; else stat -c '%i:%f:%Y:%s' "$@"; fi; }
eq() {
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3"; fi
}
field() { launch "$@" | sed -n "s/^$FIELD=//p"; }
prof() { FIELD=PROFILE field "$@"; }
err() {
  _name=$1; shift
  _out=$("$@" 2>"$S/err"); _rc=$?
  eq "$_name" 'nonzero,empty,stderr' "$([ "$_rc" -ne 0 ] && echo nonzero),$([ -z "$_out" ] && echo empty),$([ -s "$S/err" ] && echo stderr)"
}

suite_launch_and_usage() {
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
    eq linux-headless-zero-bridge 'unset|unset|unset' "$(DBUS_SESSION_BUS_ADDRESS='' XDG_RUNTIME_DIR="$S/no-bus" launch | awk -F= '/^(WSL_INTEROP|ZDOTDIR|BASH_ENV)=/{printf "%s|", $2}' | sed 's/|$//')"
  fi
  eq desktop-uses-bridge agyx "$(DBUS_SESSION_BUS_ADDRESS='unix:path=/tmp/bus' FIELD=WSL_INTEROP field)"
  touch "$S/fake-dockerenv"
  eq container-zero-bridge 'unset|unset|unset' "$(AGYX_DOCKERENV="$S/fake-dockerenv" launch | awk -F= '/^(WSL_INTEROP|ZDOTDIR|BASH_ENV)=/{printf "%s|", $2}' | sed 's/|$//')"
  for bad in Work 1a a/b doctor profile uninstall ''; do err "profile-$bad" launch --profile "$bad"; done
  err missing launch --profile
  err duplicate launch --profile work --profile personal
  err missing-dir launch --profile absent
  err env-invalid env AGYX_PROFILE=BAD "$here/bin/agy"
  mv "$DD/default" "$S/default"
  err no-default launch
  eq launch-no-default-code 3 "$(launch >/dev/null 2>&1; echo $?)"
  mv "$S/default" "$DD/default"
  eq launch-bad-profile-code 2 "$(launch --profile BAD >/dev/null 2>&1; echo $?)"
  eq launch-forbidden-flag-code 2 "$(launch --app_data_dir=x >/dev/null 2>&1; echo $?)"
  eq launch-absent-profile-code 3 "$(launch --profile absent >/dev/null 2>&1; echo $?)"
  ln -s "$DD/profiles/work" "$DD/profiles/sym"
  eq launch-symlink-code 1 "$(launch --profile sym >/dev/null 2>&1; echo $?)"
  rm "$DD/profiles/sym"
  # agyx profile usage [NAME] is agy's /usage for the current profile, or the named one; it needs a login.
  err usage-not-logged-in ax profile usage
  eq usage-not-logged-in-code 4 "$(ax profile usage >/dev/null 2>&1; echo $?)"
  for p in work personal; do (umask 077; : > "$DD/profiles/$p/antigravity-cli/antigravity-oauth-token"); done
  out=$(ax profile usage)
  eq usage-default-profile work "$(printf '%s\n' "$out" | sed -n 's/^PROFILE=//p')"
  eq usage-slash /usage "$(printf '%s\n' "$out" | sed -n 's/^ARG=//p' | tail -n 1)"
  eq usage-print-flag -p "$(printf '%s\n' "$out" | sed -n 's/^ARG=//p' | tail -n 2 | head -n 1)"
  eq usage-named personal "$(ax profile usage personal | sed -n 's/^PROFILE=//p')"
  eq usage-env personal "$(AGYX_PROFILE=personal ax profile usage | sed -n 's/^PROFILE=//p')"
  err usage-extra ax profile usage personal extra
  err usage-missing ax profile usage absent
  err usage-all-and-name ax profile usage --all personal
  # --all / --json run every logged-in profile in parallel and parse agy's TSV.
  tsv='printf "Gemini Models\tFive Hour Limit Remaining\t92%%\t2026-11-16T16:11:52Z\nnoise\nClaude and GPT models\tWeekly Limit Remaining\t43%%\t2026-11-19T07:21:07Z\n"'
  out=$(FAKE_RUN=$tsv ax profile usage --all)
  eq usage-all-lines 4 "$(printf '%s\n' "$out" | grep -c .)"
  eq usage-all-prefix 'personal|work' "$(printf '%s\n' "$out" | cut -f 1 | sort -u | paste -sd '|' -)"
  out=$(FAKE_RUN=$tsv ax profile usage --json)
  eq usage-json '[{"profile":"work","ok":true,"limits":[{"group":"Gemini Models","window":"5h","remaining":92,"resets_at":"2026-11-16T16:11:52Z"},{"group":"Claude and GPT models","window":"weekly","remaining":43,"resets_at":"2026-11-19T07:21:07Z"}]}]' "$out"
  mkdir -p "$DD/profiles/zeta/antigravity-cli"
  out=$(FAKE_RUN='echo boom >&2; exit 3' ax profile usage --all --json); rc=$?
  eq usage-all-failure-code 1 "$rc"
  eq usage-all-failure-json 1 "$(printf '%s' "$out" | grep -c '{"profile":"work","ok":false,"error":"boom"}')"
  eq usage-all-not-logged-in 1 "$(printf '%s' "$out" | grep -c '{"profile":"zeta","ok":false,"error":"not_logged_in"}')"
  out=$(FAKE_RUN='printf "unexpected banner\n"' ax profile usage --json); rc=$?
  eq usage-unrecognized-code 1 "$rc"
  eq usage-unrecognized-json '[{"profile":"work","ok":false,"error":"unexpected banner"}]' "$out"
  out=$(FAKE_RUN=':' ax profile usage --json); rc=$?
  eq usage-empty-code 1 "$rc"
  eq usage-empty-json '[{"profile":"work","ok":false,"error":"unrecognized /usage output"}]' "$out"
  rm -rf "$DD/profiles/zeta"
  for p in work personal; do rm "$DD/profiles/$p/antigravity-cli/antigravity-oauth-token"; done
  # Machine-readable profile state, exit codes, help.
  eq list-json '{"default":"work","profiles":[{"name":"personal","email":null,"logged_in":false,"default":false},{"name":"work","email":null,"logged_in":false,"default":true}]}' "$(ax profile list --json)"
  eq current-default 'work' "$(ax profile current)"
  eq current-json '{"name":"personal","source":"env","email":null,"logged_in":false}' "$(AGYX_PROFILE=personal ax profile current --json)"
  eq current-missing-code 3 "$(AGYX_PROFILE=absent ax profile current >/dev/null 2>&1; echo $?)"
  eq current-missing-json-code no_such_profile "$(AGYX_PROFILE=absent ax profile current --json 2>/dev/null | sed -n 's/.*"code":"\([a-z_]*\)".*/\1/p')"
  eq default-json '{"default":"work"}' "$(ax profile default --json)"
  eq default-set-json '{"default":"personal"}' "$(ax profile default personal --json)"
  eq default-set-file personal "$(cat "$DD/default")"
  ax profile default work >/dev/null
  eq default-notyet-code 3 "$(AGYX_DATA_DIR="$S/uninit-default" ax profile default work >/dev/null 2>&1; echo $?)"
  eq default-notyet-json-code not_set_up "$(AGYX_DATA_DIR="$S/uninit-default" ax profile default work --json 2>/dev/null | sed -n 's/.*"code":"\([a-z_]*\)".*/\1/p')"
  eq default-notyet-no-dir absent "$([ -e "$S/uninit-default" ] && echo present || echo absent)"
  eq usage-absent-code 3 "$(ax profile usage absent >/dev/null 2>&1; echo $?)"
  eq usage-absent-json-code no_such_profile "$(ax profile usage absent --json 2>/dev/null | sed -n 's/.*"code":"\([a-z_]*\)".*/\1/p')"
  eq default-absent-code 3 "$(ax profile default absent >/dev/null 2>&1; echo $?)"
  eq default-absent-json-code no_such_profile "$(ax profile default absent --json 2>/dev/null | sed -n 's/.*"code":"\([a-z_]*\)".*/\1/p')"
  eq usage-bad-name-code 2 "$(ax profile usage BAD >/dev/null 2>&1; echo $?)"
  ln -s "$DD/profiles/work" "$DD/profiles/symprof"
  eq default-symlink-code 1 "$(ax profile default symprof >/dev/null 2>&1; echo $?)"
  eq current-symlink-code 1 "$(AGYX_PROFILE=symprof ax profile current >/dev/null 2>&1; echo $?)"
  eq usage-symlink-code 1 "$(ax profile usage symprof >/dev/null 2>&1; echo $?)"
  eq usage-symlink-json-code symlink_profile "$(ax profile usage symprof --json 2>/dev/null | sed -n 's/.*"code":"\([a-z_]*\)".*/\1/p')"
  rm "$DD/profiles/symprof"
  eq help-usage 1 "$(ax profile usage --help | grep -c '^usage: agyx profile usage')"
  eq help-doctor 1 "$(ax doctor -h | grep -c '^usage: agyx doctor')"
  eq login-needs-terminal 5 "$(ax profile login someone >/dev/null 2>&1; echo $?)"
  eq login-needs-terminal-no-profile absent "$([ -e "$DD/profiles/someone" ] && echo present || echo absent)"
}

suite_discovery_and_args() {
  # A single entry, uncached PATH discovery and the official GUI fallback.
  launch >/dev/null
  eq single-entry "$here/bin/agy" "$(readlink "$DD/agy")"
  eq no-real-cache no "$([ -e "$DD/real-agy" ] || [ -L "$DD/real-agy" ] && echo yes || echo no)"
  mkdir -p "$S/native one" "$S/native-two" "$RH/.local/bin" "$S/old/bin" "$S/old/runtime" "$S/alias"
  cp "$T/fake-agy" "$S/native one/agy"
  cp "$T/fake-agy" "$S/native-two/agy"
  cp "$T/fake-agy" "$RH/.local/bin/agy"
  cp "$here/bin/agy" "$here/bin/agyx" "$S/old/bin/"
  cp "$here/runtime/"*.sh "$S/old/runtime/"
  ln -s '../native one/agy' "$S/alias/agy"
  eq path-native-first "$S/native one/agy" "$(AGYX_REAL_AGY='' PATH="$DD:$S/old/bin:$S/native one:$PATH" FIELD=EXE field)"
  eq path-reread-next-launch "$S/native-two/agy" "$(AGYX_REAL_AGY='' PATH="$S/native-two:$PATH" FIELD=EXE field)"
  eq native-alias-resolved "$S/native one/agy" "$(AGYX_REAL_AGY='' PATH="$S/alias:$PATH" FIELD=EXE field)"
  mkdir "$S/literal[one]" "$S/literaln"
  cp "$T/fake-agy" "$S/literal[one]/agy"
  cp "$T/fake-agy" "$S/literaln/agy"
  eq path-literal-no-globbing "$S/literal[one]/agy" "$(AGYX_REAL_AGY='' PATH="$S/literal[one]:$PATH" FIELD=EXE field)"
  eq native-override-resolved "$S/native one/agy" "$(AGYX_REAL_AGY="$S/alias/agy" FIELD=EXE field)"
  eq native-override-wins "$T/fake-agy" "$(PATH="$S/native-two:$PATH" FIELD=EXE field)"
  eq minimal-path-fallback "$RH/.local/bin/agy" "$(AGYX_REAL_AGY='' FIELD=EXE field)"
  eq skip-only-shims-to-fallback "$RH/.local/bin/agy" "$(AGYX_REAL_AGY='' PATH="$DD:$S/old/bin:$PATH" FIELD=EXE field)"
  # A real binary beside an agyx runtime is still native, not an agyx shell shim.
  mkdir -p "$S/collocated/bin" "$S/collocated/runtime"
  cp /usr/bin/true "$S/collocated/bin/agy"
  cp "$here/runtime/"*.sh "$S/collocated/runtime/"
  ( . "$here/runtime/sync.sh"; AGYX_SHIM=$here/bin/agy; agyx_real_candidate "$S/collocated/bin/agy" ); rc=$?
  eq native-not-rejected-by-runtime-neighbor 0 "$rc"
  err override-current-shim env AGYX_REAL_AGY="$DD/agy" "$here/bin/agy" --profile work
  err override-other-shim env AGYX_REAL_AGY="$S/old/bin/agy" "$here/bin/agy" --profile work
  ln -s "$here/bin/agyx" "$S/alias/management"
  err override-management-shim env AGYX_REAL_AGY="$S/alias/management" "$here/bin/agy" --profile work
  err override-missing-no-fallback env AGYX_REAL_AGY="$S/missing-agy" "$here/bin/agy" --profile work
  eq doctor-new-entry 1 "$(ax doctor 2>/dev/null | grep -c "agy entry: $DD/agy (in place")"
  eq doctor-native-fallback 1 "$(AGYX_REAL_AGY='' ax doctor 2>/dev/null | grep -c "^real agy: $RH/.local/bin/agy$")"
  ver=$(sed -n 's/^AGYX_VERSION=\([^ #]*\).*/\1/p' "$here/runtime/sync.sh" | head -n 1)
  eq version-string 1 "$(ax --version | grep -Fxc "agyx $ver")"
  # Only doctor above queried item existence; launches still must make no security calls.
  eq doctor-item-queries-only 2 "$(wc -l < "$SECLOG" | tr -d ' ')"
  : > "$SECLOG"
  # Help/version are strictly read-only (no disk cleanup / migration).
  mkdir -p "$DD/bin" "$DD/profiles/work/log"
  printf oldlog > "$DD/profiles/work/log/cli-old.log"
  printf stamp > "$DD/.verified"
  ln -s "$S/native one/agy" "$DD/real-agy"
  ln -s "$here/bin/agy" "$DD/bin/agy"
  ax --version >/dev/null
  ax --help >/dev/null
  eq help-version-readonly yes "$([ -L "$DD/real-agy" ] && [ -L "$DD/bin/agy" ] && [ -f "$DD/.verified" ] && [ -d "$DD/profiles/work/log" ] && echo yes)"
  rm "$DD/agy"
  ax profile usage --help >/dev/null
  ax doctor -h >/dev/null
  eq subcommand-help-readonly absent "$([ -e "$DD/agy" ] || [ -L "$DD/agy" ] && echo present || echo absent)"
  ln -s "$here/bin/agy" "$DD/agy"
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
  err official-missing env HOME="$S/no-native-home" AGYX_DATA_DIR="$S/no-native-data" AGYX_REAL_AGY='' "$here/bin/agyx" profile login p
  eq missing-native-no-setup no "$([ -e "$S/no-native-data" ] && echo yes || echo no)"
  (env AGYX_DATA_DIR="$S/gui-data" AGYX_REAL_AGY='' AGYX_ASSUME_YES=1 AGYX_TTY=/dev/null FAKE_LOGIN=1 "$here/bin/agyx" profile login p >/dev/null 2>&1)
  eq gui-first-setup-entry "$here/bin/agy" "$(readlink "$S/gui-data/agy")"
  # The app flag precedes all subcommands; agyx never injects --log-file (native agy manages logs).
  for cmd in interactive -p acp mcp login logout models agent agents plugins plugin remote-control mic-serve install help changelog update --help -h --version; do
    if [ "$cmd" = interactive ]; then out=$(launch); else out=$(launch "$cmd"); fi
    first=$(printf '%s\n' "$out" | grep '^ARG=' | head -n 1)
    eq "app-first-$cmd" 1 "$(printf '%s\n' "$first" | grep -c '^ARG=--app_data_dir=')"
    eq "no-injected-log-$cmd" 0 "$(printf '%s\n' "$out" | grep -c '^ARG=--log-file$')"
  done
  out=$(launch --profile work -- 'hello world' '' --profile personal -- x)
  eq argv 'ARG=hello world|ARG=|ARG=--profile|ARG=personal|ARG=--|ARG=x|' "$(printf '%s\n' "$out" | grep '^ARG=' | tail -n 6 | tr '\n' '|')"
  eq own-log 1 "$(launch --log-file "$S/own.log" | grep -c '^ARG=--log-file$')"
  err override-app launch --app_data_dir=elsewhere
  err override-gemini launch --gemini_dir /elsewhere
  err override-single-dash launch -app_data_dir=elsewhere
  # Resolve the relative argument, including spaces and data outside HOME.
  out=$(launch)
  rel=$(printf '%s\n' "$out" | sed -n 's/^ARG=--app_data_dir=//p')
  eq relative-target "$(cd "$DD/profiles/work/antigravity-cli" && pwd -P)" "$(cd "$RH/.gemini/$rel" && pwd -P)"
  mkdir -p "$S/space data/profiles/p/antigravity-cli"
  out=$(AGYX_DATA_DIR="$S/space data" launch --profile p)
  rel=$(printf '%s\n' "$out" | sed -n 's/^ARG=--app_data_dir=//p')
  eq space-target "$(cd "$S/space data/profiles/p/antigravity-cli" && pwd -P)" "$(cd "$RH/.gemini/$rel" && pwd -P)"
  eq no-keychain-launches '' "$(cat "$SECLOG")"
}

suite_bridge() {
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
    eq "$shell-internal-globals-cleaned" 'AGYX_DATA_DIR AGYX_PROFILE AGYX_REAL_AGY ' "$(AGYX_HOME=/leak AGYX_DATA=/leak AGYX_SHIM=/leak AGYX_REAL=/leak FAKE_RUN="$shell -c '$routing'" launch | sort | tr '\n' ' ')"
    eq "$shell-native-env-kept" '/native-api|kept' "$(ANTIGRAVITY_AGENTAPI_EXE=/native-api AGY_CLI_PROBE=kept FAKE_RUN="$shell -c 'printf \"%s|%s\" \"\$ANTIGRAVITY_AGENTAPI_EXE\" \"\$AGY_CLI_PROBE\"'" launch)"
  done
  mkdir -p "$S/zd"
  printf '[ ! "${AGYX_ORIG_WSL_INTEROP+x}" ] || printf leak >> "$COUNT"\nprintf x >> "$COUNT"\n' > "$S/zd/.zshenv"
  printf '[ ! "${AGYX_ORIG_WSL_INTEROP+x}" ] || printf leak >> "$COUNT"\nprintf x >> "$COUNT"\n' > "$S/benv"
  export COUNT=$S/count
  if command -v zsh >/dev/null 2>&1; then
    : > "$COUNT"
    (ZDOTDIR=$S/zd FAKE_RUN='zsh -c true' launch >/dev/null)
    eq zshenv-once x "$(cat "$COUNT")"
  fi
  : > "$COUNT"
  (BASH_ENV=$S/benv FAKE_RUN='bash -c true' launch >/dev/null)
  eq bashenv-once x "$(cat "$COUNT")"
}

suite_env_sanitize() {
  # Caller AGYX_* variables (such as AGYX_TAP_DIR from release.sh) must be sanitized by test/run.sh.
  out=$(AGYX_TAP_DIR=/tmp/x AGYX_CUSTOM_LEAK=1 sh "$here/test/run.sh" --suite suite_bridge </dev/null 2>&1); rc=$?
  eq env-sanitize-exit 0 "$rc"
  eq env-sanitize-zero-fail 1 "$(printf '%s\n' "$out" | grep -c 'failed: 0$')"
}

suite_sync_and_sqlite() {
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
    mkdir -p "$S/sqlite/shared" "$S/sqlite/one" "$S/sqlite/two"
    sqldb=$S/sqlite/shared/test.db
    sqlite3 "$sqldb" 'PRAGMA journal_mode=WAL; CREATE TABLE t(n);' >/dev/null
    ln -s "$sqldb" "$S/sqlite/one/test.db"
    ln -s "$sqldb" "$S/sqlite/two/test.db"
    sqlite3 "$S/sqlite/one/test.db" <<EOF &
BEGIN IMMEDIATE;
INSERT INTO t VALUES(1);
.shell touch "$S/sqlite/ready"
.shell sleep 1
COMMIT;
EOF
    sqlite_pid=$!
    i=0
    while [ ! -f "$S/sqlite/ready" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    eq sqlite-shared-wal-shm yes "$([ -f "$sqldb-wal" ] && [ -f "$sqldb-shm" ] && echo yes)"
    eq sqlite-no-profile-sidecars no "$(find "$S/sqlite/one" "$S/sqlite/two" -type f | grep -q . && echo yes || echo no)"
    sqlite3 "$S/sqlite/two/test.db" 'BEGIN IMMEDIATE;' 2>"$S/sqlite/error"; rc=$?
    eq sqlite-shared-writer-lock 1 "$([ "$rc" -ne 0 ] && grep -q 'database is locked' "$S/sqlite/error" && echo 1)"
    wait "$sqlite_pid"; rc=$?
    eq sqlite-first-commit 0 "$rc"
    sqlite3 "$S/sqlite/two/test.db" 'BEGIN IMMEDIATE; INSERT INTO t VALUES(2); COMMIT;'
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
  mkdir -p "$shared/daemon"
  printf shared-daemon > "$shared/daemon/info.json"
  ln -s "$shared/daemon" "$app/daemon"
  launch >/dev/null
  eq former-shared-daemon-detached no "$([ -L "$app/daemon" ] && echo yes || echo no)"
  mkdir -p "$app/daemon"
  printf work-daemon > "$app/daemon/info.json"
  launch >/dev/null
  eq private-daemon-not-adopted shared-daemon "$(cat "$shared/daemon/info.json")"
  eq private-daemon-kept work-daemon "$(cat "$app/daemon/info.json")"
  eq doctor-daemon-no-drift 0 "$(ax doctor 2>/dev/null | grep -c 'antigravity-cli daemon: DRIFT')"
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
  err profile-login-symlink env AGYX_TTY=/dev/null "$here/bin/agyx" profile login alias
  rm "$DD/profiles/alias"
}

suite_exec_and_storage() {
  # Direct exec + doctor binary check + native log storage guards preserve PID, stdin, exit status and INT/TERM/HUP.
  app=$DD/profiles/work/antigravity-cli
  cat > "$S/unmarked-agy" <<'EOF'
#!/bin/sh
printf 'PROFILE=%s\n' "$AGYX_PROFILE"
exit "${FAKE_STATUS:-0}"
EOF
  chmod +x "$S/unmarked-agy"
  (AGYX_REAL_AGY="$S/unmarked-agy" FAKE_STATUS=7 launch -p hello >"$S/out" 2>"$S/err"); rc=$?
  eq storage-unmarked-status 7 "$rc"
  eq storage-unmarked-stdout 1 "$(grep -c '^PROFILE=work$' "$S/out")"
  eq storage-no-verified-file no "$([ -e "$DD/.verified" ] && echo yes || echo no)"
  (AGYX_REAL_AGY="$S/unmarked-agy" ax doctor >/dev/null 2>"$S/err")
  eq doctor-unmarked-binary-warning 1 "$(grep -c 'WARNING: file-based token storage markers NOT confirmed' "$S/err")"
  eq storage-warning-risk 1 "$(grep -c 'keychain fallback can mix accounts and delete the profile token file' "$S/err")"
  (FAKE_STORAGE=keychain launch >/dev/null 2>"$S/err"); rc=$?
  eq storage-keychain-first-exit 0 "$rc"
  # Next launch sees the previous non-empty bad native log and warns before exec.
  launch mcp list >/dev/null 2>"$S/err"
  eq storage-recent-log-warning 1 "$(grep -c 'WARNING: file-based token storage NOT confirmed' "$S/err")"
  launch >/dev/null 2>"$S/err"
  launch >/dev/null 2>"$S/err"
  eq storage-wsl-clears-warning '' "$(cat "$S/err")"
  (FAKE_LOGIN=1 FAKE_STORAGE=keychain AGYX_TTY=/dev/null ax profile login badstore >/dev/null 2>"$S/err")
  eq storage-login-immediate-warning 1 "$(grep -c 'WARNING: file-based token storage NOT confirmed' "$S/err")"
  eq storage-login-temp-cleaned 0 "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'agyx-login-*' 2>/dev/null | wc -l | tr -d ' ')"
  rm -rf "$DD/profiles/badstore"
  eq storage-stdin 'stdin preserved' "$(printf 'stdin preserved\n' | FAKE_RUN='IFS= read -r line; printf "%s" "$line"' launch)"
  # Direct exec means no wrapper shell sits above agy, and INT/TERM/HUP all arrive with default dispositions intact.
  FAKE_RUN='printf %s "$$" > "$S/child-pid"' S=$S "$here/bin/agy" >/dev/null &
  spawned_pid=$!
  wait "$spawned_pid"
  eq exec-direct-pid "$spawned_pid" "$(cat "$S/child-pid")"
  export READY=$S/guard-ready
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
      ' _ "$here" "$S" "$sig"
    )
    eq "exec-$sig-status" 23 "$rc"
    eq "exec-$sig-no-warning" '' "$(cat "$S/err")"
  done
  # Newest log only: an older positive marker cannot hide a new keychain fallback.
  mkdir -p "$app/log"
  printf 'Using file-based token storage because WSL environment detected\n' > "$app/log/guard-old.log"
  sleep 1
  printf 'Using keychain token storage\n' > "$app/log/guard-new.log"
  ax doctor >/dev/null 2>"$S/err"
  eq doctor-storage-newest 1 "$(grep -c 'NOT confirmed in .*work/antigravity-cli/log/guard-new.log' "$S/err")"
  printf 'Using file-based token storage because SSH environment detected\n' >> "$app/log/guard-new.log"
  ax doctor >/dev/null 2>"$S/err"
  eq doctor-storage-confirmed 0 "$(grep -c 'NOT confirmed in .*work/antigravity-cli/log/' "$S/err")"
}

suite_login_and_doctor() {
  shared=$RH/.gemini/antigravity-cli app=$DD/profiles/work/antigravity-cli
  launch >/dev/null
  # Token existence only; no parser needed, email comes from own launch log.
  (FAKE_LOGIN=1 AGYX_TTY=/dev/null ax profile login new >/dev/null)
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
  (FAKE_LOGIN=1 AGYX_TTY=/dev/null ax profile login next >/dev/null 2>&1)
  eq first-default next "$(cat "$DD/default")"
  eq duplicate-warning 1 "$(ax profile list 2>&1 >/dev/null | grep -c '^WARNING: profiles')"
  (FAKE_LOGIN=1 FAKE_EMAIL='' AGYX_TTY=/dev/null ax profile login next >/dev/null 2>&1)
  eq no-stale-login-email 1 "$(ax profile list | grep -c '^next .*logged in, email unknown')"
  eq stale-email 1 "$(ax profile list | grep -c '^personal .*not logged in')"
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
  eq doctor-issues-code 1 "$(ax doctor >/dev/null 2>&1; echo $?)"
  out=$(ax doctor --json 2>/dev/null)
  eq doctor-json-shape 1 "$(printf '%s' "$out" | grep -c '^{"ok":false,"issues":\[".*"\],"report":\[".*"\]}$')"
  eq doctor-json-has-issue 1 "$(printf '%s' "$out" | grep -c 'token: WARNING mode 644')"
  # Structured doctor issue tracking catches every issue category directly (no grep prose scraper).
  chmod 755 "$DD/profiles/work"
  rm -f "$DD/agy"
  printf 'custom\n' > "$DD/agy"
  cat > "$S/unmarked" <<'EOF'
#!/bin/sh
echo "agy 0.0.0"
EOF
  chmod +x "$S/unmarked"
  mkdir -p "$app/log"
  printf 'Using keychain token storage\n' > "$app/log/z-bad.log"
  out=$(AGYX_REAL_AGY="$S/unmarked" ax doctor --json 2>/dev/null); rc=$?
  eq doctor-structured-rc 1 "$rc"
  eq doctor-structured-unmarked 1 "$(printf '%s' "$out" | grep -c 'file-based token storage markers NOT confirmed')"
  eq doctor-structured-bad-entry 1 "$(printf '%s' "$out" | grep -c 'is MISSING or not agyx')"
  eq doctor-structured-dir-mode 1 "$(printf '%s' "$out" | grep -c 'permissions: WARNING .* mode 755')"
  eq doctor-structured-token-mode 1 "$(printf '%s' "$out" | grep -c 'token: WARNING mode 644')"
  eq doctor-structured-broken-link 1 "$(printf '%s' "$out" | grep -c 'antigravity-cli broken: WARNING broken or unexpected link')"
  eq doctor-structured-drift 1 "$(printf '%s' "$out" | grep -c 'antigravity-cli collision: DRIFT')"
  eq doctor-structured-bad-log 1 "$(printf '%s' "$out" | grep -c 'file-based token storage NOT confirmed in .*z-bad.log')"
  out=$(AGYX_REAL_AGY='' ax doctor --json 2>/dev/null); rc=$?
  eq doctor-structured-missing-real-rc 1 "$rc"
  eq doctor-structured-missing-real 1 "$(printf '%s' "$out" | grep -c 'real agy: NOT FOUND')"
  # Clean state reports ok:true and empty issues array.
  mkdir -p "$S/clean-bin"
  ln -s "$here/bin/agyx" "$S/clean-bin/agyx"
  chmod 700 "$DD/profiles/work" "$DD/profiles/work/antigravity-cli" "$DD/profiles/personal" "$DD/profiles/personal/antigravity-cli"
  chmod 600 "$app/antigravity-oauth-token"
  rm -f "$app/collision" "$app/broken" "$app/log/z-bad.log" "$DD/agy"
  ln -s "$here/bin/agy" "$DD/agy"
  out=$(PATH="$S/clean-bin:$PATH" ax doctor --json 2>/dev/null); rc=$?
  eq doctor-clean-rc 0 "$rc"
  eq doctor-clean-json 1 "$(printf '%s' "$out" | grep -c '^{"ok":true,"issues":\[\],"report":\[')"
}

suite_shared_repair() {
  # Fresh profiles share every known entry before either fake native process writes.
  fr=$S/shared-repair frhome=$S/shared-repair/home frdata=$S/shared-repair/data
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
  eq drift-no-tty-code 5 "$(fresh_run "$here/bin/agy" --profile one >/dev/null 2>&1; echo $?)"
  eq drift-no-tty-kept profile-only "$(cat "$one/conversations/only")"
  eq drift-no-tty-no-trash no "$([ -e "$fr/trash" ] && echo yes || echo no)"
  eq drift-doctor-still-reports 1 "$(fresh_run "$here/bin/agyx" doctor 2>/dev/null | grep -c 'antigravity-cli conversations: DRIFT')"
  eq drift-doctor-no-repair profile-only "$(cat "$one/conversations/only")"
  err drift-declined fresh_run AGYX_TTY="$fr/no" "$here/bin/agy" --profile one
  eq drift-declined-kept profile-db "$(cat "$one/conversation_summaries.db")"
  # A running native writer prevents repair even when consent is supplied.
  "$T/writer with spaces" "$fr/ready" "$fs/conversation_summaries.db" & writer=$!
  i=0; while [ ! -f "$fr/ready" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  err drift-busy fresh_run AGYX_REAL_AGY="$T/writer with spaces" AGYX_ASSUME_YES=1 "$here/bin/agy" --profile one
  eq drift-busy-diagnostic 1 "$(grep -c 'close agy before shared repair' "$S/err")"
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
  mkdir -p "$S/preconsent/home" "$S/preconsent/data/profiles/p/antigravity-cli/brain"
  err repair-refusal-no-shared-dir env HOME="$S/preconsent/home" AGYX_DATA_DIR="$S/preconsent/data" AGYX_TTY="$fr/no" "$here/bin/agy" --profile p
  eq repair-refusal-zero-gemini absent "$([ -e "$S/preconsent/home/.gemini" ] && echo present || echo absent)"
  # Concurrent preparers wait for an active preparation, and still fail if a stale lock remains.
  mkdir "$frdata/.lock"
  err prepare-lock-busy fresh_run AGYX_LOCK_TRIES=2 "$here/bin/agy" --profile one
  eq prepare-lock-busy-code 1 "$(fresh_run AGYX_LOCK_TRIES=2 "$here/bin/agy" --profile one >/dev/null 2>&1; echo $?)"
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
}

suite_gate_and_uninstall() {
  shared=$RH/.gemini/antigravity-cli app=$DD/profiles/work/antigravity-cli
  mkdir -p "$shared"
  printf history > "$shared/history.jsonl"
  printf database > "$shared/conversation_summaries.db"
  launch >/dev/null
  # First-run gate: read-only commands and refusal leave disk alone.
  fresh=$S/fresh
  for command in '--help' '--version' 'profile list' 'profile default' doctor; do
    # shellcheck disable=SC2086 # fixed command words above
    (AGYX_DATA_DIR=$fresh ax $command >/dev/null 2>&1)
    eq "readonly-$command" absent "$([ -e "$fresh" ] && echo present || echo absent)"
  done
  err first-nonterminal env AGYX_DATA_DIR="$fresh" "$here/bin/agyx" profile login p
  eq notyet-code 3 "$(AGYX_DATA_DIR=$fresh ax doctor >/dev/null 2>&1; echo $?)"
  eq notyet-list-empty-ok 0 "$(AGYX_DATA_DIR=$fresh ax profile list >/dev/null 2>&1; echo $?)"
  eq notyet-list-json '{"default":null,"profiles":[]}' "$(AGYX_DATA_DIR=$fresh ax profile list --json 2>/dev/null)"
  eq gate-nonterminal-code 5 "$(env AGYX_DATA_DIR="$fresh" "$here/bin/agy" >/dev/null 2>&1; echo $?)"
  printf 'n\n' > "$S/no"
  err first-no env AGYX_DATA_DIR="$fresh" AGYX_TTY="$S/no" "$here/bin/agyx" profile login p
  printf 'y\n' > "$S/yes"
  (AGYX_DATA_DIR=$fresh AGYX_TTY=$S/yes ax profile login p >/dev/null 2>"$S/err")
  eq first-yes present "$([ -d "$fresh/profiles/p/antigravity-cli" ] && echo present)"
  eq no-whitelist absent "$([ -e "$RH/.config/agyx/symlinks" ] && echo present || echo absent)"
  # Uninstall fixture + shared native-agy token (agyx never touches ~/.gemini).
  udata=$S/uninstall-data
  mkdir -p "$udata/profiles/old/antigravity-cli"
  printf plain-agy > "$shared/antigravity-oauth-token"
  # Uninstall ignores plain native agy, including when plain agy holds open shared conversation_summaries.db
  # and an installed profile symlinks conversation_summaries.db to that shared file.
  "$T/writer with spaces" "$S/plain-ready" "$T/fake-agy" & plain_writer=$!
  i=0; while [ ! -f "$S/plain-ready" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  mkdir -p "$S/uninst-plain/profiles/p/antigravity-cli"
  (AGYX_DATA_DIR=$S/uninst-plain AGYX_ASSUME_YES=1 ax uninstall >/dev/null 2>"$S/err"); rc=$?
  eq uninstall-ignores-plain-agy 0 "$rc"
  kill "$plain_writer"; wait "$plain_writer" 2>/dev/null
  "$T/writer with spaces" "$S/shared-db-ready" "$shared/conversation_summaries.db" & shared_writer=$!
  i=0; while [ ! -f "$S/shared-db-ready" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  mkdir -p "$S/uninst-shared/profiles/p/antigravity-cli"
  ln -s "$shared/conversation_summaries.db" "$S/uninst-shared/profiles/p/antigravity-cli/conversation_summaries.db"
  (AGYX_DATA_DIR=$S/uninst-shared AGYX_ASSUME_YES=1 ax uninstall >/dev/null 2>"$S/err"); rc=$?
  eq uninstall-ignores-shared-db-writer 0 "$rc"
  eq uninstall-shared-db-removed absent "$([ -e "$S/uninst-shared" ] && echo present || echo absent)"
  kill "$shared_writer"; wait "$shared_writer" 2>/dev/null
  # Uninstall refuses when a live agyx profile holds open its own private log file.
  mkdir -p "$app/log"
  printf 'Using file-based token storage\n' > "$app/log/cli-native.log"
  "$T/writer with spaces" "$S/uninstall-ready" "$app/log/cli-native.log" & writer=$!
  i=0; while [ ! -f "$S/uninstall-ready" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  err uninstall-live-profile env AGYX_ASSUME_YES=1 "$here/bin/agyx" uninstall
  eq uninstall-live-profile-diagnostic 1 "$(grep -c 'agy is still running' "$S/err")"
  eq uninstall-live-profile-preserved yes "$([ -d "$DD/profiles/work" ] && echo yes)"
  kill "$writer"; wait "$writer" 2>/dev/null
  # Uninstall refusal, then Trash; shared state and plain agy are retained.
  err uninstall-no env AGYX_DATA_DIR="$udata" AGYX_TTY="$S/no" "$here/bin/agyx" uninstall
  (AGYX_DATA_DIR=$udata AGYX_ASSUME_YES=1 ax uninstall >/dev/null 2>"$S/err")
  eq uninstall-data-gone absent "$([ -e "$udata" ] && echo present || echo absent)"
  eq uninstall-data-trash 1 "$(find "$AGYX_TRASH_DIR" -path '*/data/profiles/old/antigravity-cli' | wc -l | tr -d ' ')"
  eq uninstall-plain-token-kept plain-agy "$(cat "$shared/antigravity-oauth-token")"
  eq uninstall-shared-history-kept history "$(cat "$shared/history.jsonl")"
  # Existing helpers: stable Homebrew path, stale shim entry repair, non-agyx entry left alone.
  rm "$DD/agy"; ln -s "$S/gone/opt/agyx/libexec/bin/agy" "$DD/agy"
  launch >/dev/null
  eq repaired-entry "$here/bin/agy" "$(readlink "$DD/agy")"
  mkdir -p "$S/prefix/Cellar/agyx/0.1.3/bin" "$S/prefix/opt"
  printf x > "$S/prefix/Cellar/agyx/0.1.3/bin/agy"
  ln -s ../Cellar/agyx/0.1.3 "$S/prefix/opt/agyx"
  eq stable-path "$S/prefix/opt/agyx/bin/agy" "$(. "$here/runtime/sync.sh"; agyx_stable "$S/prefix/Cellar/agyx/0.1.3/bin/agy"; echo "$AGYX_STABLE")"
  # A Homebrew install of the beta formula agyx-beta behaves like agyx: Cellar paths map to its own
  # opt path, and agyx uninstall removes the formula it was installed as.
  mkdir -p "$S/binstub"
  printf '#!/bin/sh\necho "brew $*" >> "$BREWLOG"\n' > "$S/binstub/brew"
  chmod +x "$S/binstub/brew"
  export BREWLOG=$S/brew.log
  brewtest() { # $1 = Cellar dir (formula/version), $2 = opt name, $3 = formula brew must uninstall
    d=$S/prefix/Cellar/$1
    mkdir -p "$d/libexec/bin" "$d/libexec/runtime" "$S/prefix/opt" "$S/bdata"
    cp "$here/bin/agyx" "$here/bin/agy" "$d/libexec/bin/"
    cp "$here/runtime/"*.sh "$d/libexec/runtime/"
    ln -sfn "../Cellar/$1" "$S/prefix/opt/$2"
    eq "stable-$2-path" "$S/prefix/opt/$2/libexec/bin/agy" "$(. "$here/runtime/sync.sh"; agyx_stable "$d/libexec/bin/agy"; echo "$AGYX_STABLE")"
    (AGYX_DATA_DIR=$S/bdata AGYX_ASSUME_YES=1 PATH="$S/binstub:$PATH" "$d/libexec/bin/agyx" uninstall >/dev/null 2>"$S/err-$2")
    eq "uninstall-$2-formula" "brew uninstall $3" "$(tail -n 1 "$BREWLOG")"
    eq "uninstall-$2-hint" "1" "$(grep -c "(brew uninstall $3)" "$S/err-$2")"
  }
  : > "$BREWLOG"
  brewtest agyx/0.2.0 agyx agyx
  brewtest agyx-beta/0.2.0-beta.9 agyx-beta agyx-beta
  # Linux/XDG trash base fallback when AGYX_TRASH_DIR is unset and ~/.Trash does not exist.
  eq xdg-trash-fallback "$S/xdg-data/Trash/files" "$(unset AGYX_TRASH_DIR; XDG_DATA_HOME=$S/xdg-data AGYX_HOME=$S/linux-home; . "$here/runtime/sync.sh"; AGYX_OS=Linux; agyx_trash_base)"
  # curl|sh style prefix install: bin+runtime under ~/.local/lib/agyx, PATH link, uninstall removes both.
  IP=$S/rh-install
  mkdir -p "$IP"
  (HOME=$IP sh "$here/scripts/install.sh" --from "$here" --prefix "$IP/.local/lib/agyx" --bin-dir "$IP/.local/bin" >/dev/null)
  eq install-prefix-marker "$(sed -n 's/^AGYX_VERSION=\([^ #]*\).*/\1/p' "$here/runtime/sync.sh")" "$(cat "$IP/.local/lib/agyx/.agyx-prefix")"
  eq install-prefix-link "$IP/.local/lib/agyx/bin/agyx" "$(readlink "$IP/.local/bin/agyx")"
  eq install-prefix-version "agyx $(cat "$IP/.local/lib/agyx/.agyx-prefix")" "$(HOME=$IP "$IP/.local/bin/agyx" --version | head -n 1)"
  mkdir -p "$IP/.local/share/agyx/profiles/work/antigravity-cli"
  (HOME=$IP AGYX_ASSUME_YES=1 "$IP/.local/bin/agyx" uninstall >/dev/null 2>"$S/err-prefix")
  eq uninstall-prefix-program absent "$([ -e "$IP/.local/lib/agyx" ] && echo present || echo absent)"
  eq uninstall-prefix-link absent "$([ -e "$IP/.local/bin/agyx" ] && echo present || echo absent)"
  eq uninstall-prefix-data-trashed 1 "$(find "$AGYX_TRASH_DIR" -path '*/data/profiles/work/antigravity-cli' | wc -l | tr -d ' ')"
}

suite_fastpath_and_remove() {
  shared=$RH/.gemini/antigravity-cli
  mkdir -p "$shared" "$S/alias"
  printf history > "$shared/history.jsonl"
  printf database > "$shared/conversation_summaries.db"
  printf 'n\n' > "$S/no"
  # Fast-path passthrough via bin/agyx (including symlinked agyx and strictly read-only --help).
  fpdata=$S/fastpath-data
  mkdir -p "$fpdata/profiles/work/antigravity-cli" "$fpdata/profiles/personal/antigravity-cli"
  printf 'work\n' > "$fpdata/default"
  eq fastpath-default-launch work "$(AGYX_DATA_DIR=$fpdata ax | sed -n 's/^PROFILE=//p')"
  out=$(AGYX_DATA_DIR=$fpdata ax --profile personal -p hi)
  eq fastpath-profile-launch personal "$(printf '%s\n' "$out" | sed -n 's/^PROFILE=//p')"
  eq fastpath-args '-p|hi' "$(printf '%s\n' "$out" | sed -n 's/^ARG=//p' | tail -n 2 | paste -sd '|' -)"
  ln -s "$here/bin/agyx" "$S/alias/agyx-link"
  eq fastpath-symlink-launch personal "$(AGYX_DATA_DIR=$fpdata "$S/alias/agyx-link" --profile personal | sed -n 's/^PROFILE=//p')"
  (AGYX_DATA_DIR="$S/fastpath-help-uninit" ax --help >/dev/null 2>&1); rc=$?
  eq fastpath-help-code 0 "$rc"
  eq fastpath-help-readonly absent "$([ -e "$S/fastpath-help-uninit" ] && echo present || echo absent)"
  # agyx profile remove (and rm alias): validation, TTY/busy guards, Trash move, default update, JSON.
  rdata=$S/remove-data rtrash=$S/remove-trash
  mkdir -p "$rdata/profiles/alpha/antigravity-cli/log" "$rdata/profiles/beta/antigravity-cli" "$rdata/profiles/gamma/antigravity-cli" "$rdata/profiles/delta/antigravity-cli" "$rtrash"
  printf 'alpha\n' > "$rdata/default"
  ln -s "$shared/conversation_summaries.db" "$rdata/profiles/alpha/antigravity-cli/conversation_summaries.db"
  ln -s "$shared/conversation_summaries.db" "$rdata/profiles/beta/antigravity-cli/conversation_summaries.db"
  ln -s "$shared/conversation_summaries.db" "$rdata/profiles/delta/antigravity-cli/conversation_summaries.db"
  printf 'logdata\n' > "$rdata/profiles/alpha/antigravity-cli/log/cli-native.log"
  ln -s "$rdata/profiles/alpha" "$rdata/profiles/symrm"
  eq remove-help 1 "$(ax profile remove --help | grep -c '^usage: agyx profile remove')"
  eq remove-rm-help 1 "$(ax profile rm --help | grep -c '^usage: agyx profile remove')"
  eq remove-missing-arg-code 2 "$(AGYX_DATA_DIR=$rdata ax profile remove >/dev/null 2>&1; echo $?)"
  eq remove-bad-name-code 2 "$(AGYX_DATA_DIR=$rdata ax profile remove BAD >/dev/null 2>&1; echo $?)"
  eq remove-reserved-name-code 2 "$(AGYX_DATA_DIR=$rdata ax profile remove doctor >/dev/null 2>&1; echo $?)"
  eq remove-uninit-code 3 "$(AGYX_DATA_DIR="$S/remove-uninit" ax profile remove alpha >/dev/null 2>&1; echo $?)"
  eq remove-uninit-json-code not_set_up "$(AGYX_DATA_DIR="$S/remove-uninit" ax profile remove alpha --json 2>/dev/null | sed -n 's/.*"code":"\([a-z_]*\)".*/\1/p')"
  eq remove-uninit-no-dir absent "$([ -e "$S/remove-uninit" ] && echo present || echo absent)"
  eq remove-absent-code 3 "$(AGYX_DATA_DIR=$rdata ax profile remove absent >/dev/null 2>&1; echo $?)"
  eq remove-absent-json-code no_such_profile "$(AGYX_DATA_DIR=$rdata ax profile remove absent --json 2>/dev/null | sed -n 's/.*"code":"\([a-z_]*\)".*/\1/p')"
  eq remove-symlink-code 1 "$(AGYX_DATA_DIR=$rdata ax profile remove symrm >/dev/null 2>&1; echo $?)"
  eq remove-symlink-json-code symlink_profile "$(AGYX_DATA_DIR=$rdata ax profile remove symrm --json 2>/dev/null | sed -n 's/.*"code":"\([a-z_]*\)".*/\1/p')"
  rm "$rdata/profiles/symrm"
  eq remove-no-tty-code 5 "$(AGYX_DATA_DIR=$rdata ax profile remove beta >/dev/null 2>&1; echo $?)"
  eq remove-no-tty-json-code needs_terminal "$(AGYX_DATA_DIR=$rdata ax profile remove beta --json 2>/dev/null | sed -n 's/.*"code":"\([a-z_]*\)".*/\1/p')"
  eq remove-no-tty-intact present "$([ -d "$rdata/profiles/beta" ] && echo present || echo absent)"
  eq remove-declined-code 1 "$(AGYX_DATA_DIR=$rdata AGYX_TTY="$S/no" ax profile remove beta >/dev/null 2>&1; echo $?)"
  eq remove-declined-intact present "$([ -d "$rdata/profiles/beta" ] && echo present || echo absent)"
  # Busy private log blocks removal; open shared DB does NOT block removing an idle profile.
  "$T/writer with spaces" "$S/rm-log-ready" "$rdata/profiles/alpha/antigravity-cli/log/cli-native.log" & rm_log_writer=$!
  i=0; while [ ! -f "$S/rm-log-ready" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  eq remove-busy-log-code 1 "$(AGYX_DATA_DIR=$rdata AGYX_TRASH_DIR=$rtrash ax profile remove alpha --yes >/dev/null 2>"$S/rm-err"; echo $?)"
  eq remove-busy-log-json-code profile_busy "$(AGYX_DATA_DIR=$rdata AGYX_TRASH_DIR=$rtrash ax profile remove alpha --yes --json 2>/dev/null | sed -n 's/.*"code":"\([a-z_]*\)".*/\1/p')"
  eq remove-busy-log-intact present "$([ -d "$rdata/profiles/alpha" ] && echo present || echo absent)"
  kill "$rm_log_writer"; wait "$rm_log_writer" 2>/dev/null
  "$T/writer with spaces" "$S/rm-shared-ready" "$shared/conversation_summaries.db" & rm_shared_writer=$!
  i=0; while [ ! -f "$S/rm-shared-ready" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  # Remove non-default profile (delta) while shared DB is held open: succeeds, default preserved, stdout empty without --json.
  out=$(AGYX_DATA_DIR=$rdata AGYX_TRASH_DIR=$rtrash ax profile remove delta --yes 2>"$S/rm-err"); rc=$?
  eq remove-nondefault-code 0 "$rc"
  eq remove-nondefault-stdout-empty '' "$out"
  eq remove-nondefault-default-kept alpha "$(cat "$rdata/default")"
  eq remove-nondefault-trashed 1 "$(find "$rtrash" -path '*/agyx-profile-delta-*/delta/antigravity-cli' | wc -l | tr -d ' ')"
  kill "$rm_shared_writer"; wait "$rm_shared_writer" 2>/dev/null
  # Remove default profile (alpha) when 2+ profiles remain (beta, gamma): clears default.
  out=$(AGYX_DATA_DIR=$rdata AGYX_TRASH_DIR=$rtrash ax profile remove alpha --yes --json 2>"$S/rm-err"); rc=$?
  eq remove-default-multi-code 0 "$rc"
  eq remove-default-multi-json '{"removed":"alpha","default":null}' "$out"
  eq remove-default-multi-cleared absent "$([ -e "$rdata/default" ] && echo present || echo absent)"
  eq remove-default-multi-trashed 1 "$(find "$rtrash" -path '*/agyx-profile-alpha-*/alpha/antigravity-cli' | wc -l | tr -d ' ')"
  # Remove default profile (beta) via rm alias when 1 profile remains (gamma): promotes sole remaining profile.
  printf 'beta\n' > "$rdata/default"
  out=$(AGYX_DATA_DIR=$rdata AGYX_TRASH_DIR=$rtrash ax profile rm beta --yes --json 2>"$S/rm-err"); rc=$?
  eq remove-rm-promote-code 0 "$rc"
  eq remove-rm-promote-json '{"removed":"beta","default":"gamma"}' "$out"
  eq remove-rm-promote-file gamma "$(cat "$rdata/default")"
  # Remove last remaining default profile (gamma): clears default.
  out=$(AGYX_DATA_DIR=$rdata AGYX_TRASH_DIR=$rtrash ax profile remove gamma --yes --json 2>"$S/rm-err"); rc=$?
  eq remove-last-code 0 "$rc"
  eq remove-last-json '{"removed":"gamma","default":null}' "$out"
  eq remove-last-default-cleared absent "$([ -e "$rdata/default" ] && echo present || echo absent)"
  eq remove-shared-untouched history "$(cat "$shared/history.jsonl")"
}

total_pass=0 total_fail=0
run_suite() {
  _sn=$1
  if [ -n "$only_suite" ] && [ "$only_suite" != "$_sn" ]; then return 0; fi
  (
    S=$T/$_sn
    export HOME=$S/home AGYX_DATA_DIR=$S/data AGYX_TRASH_DIR=$S/trash TMPDIR=$S/tmp SECLOG=$S/security.log
    RH=$HOME DD=$AGYX_DATA_DIR
    mkdir -p "$HOME" "$TMPDIR" "$DD/profiles/work/antigravity-cli" "$DD/profiles/personal/antigravity-cli" "$AGYX_TRASH_DIR"
    : > "$SECLOG"
    printf 'work\n' > "$DD/default"
    pass=0 fail=0
    "$_sn"
    printf '%s %s\n' "$pass" "$fail" > "$S/.counts"
  )
  _sp=0 _sf=0
  if [ -f "$T/$_sn/.counts" ]; then
    read -r _sp _sf < "$T/$_sn/.counts"
  else
    _sf=1
    printf 'FAIL %s (suite aborted)\n' "$_sn"
  fi
  total_pass=$((total_pass + _sp))
  total_fail=$((total_fail + _sf))
}

for _suite in \
  suite_launch_and_usage \
  suite_discovery_and_args \
  suite_bridge \
  suite_env_sanitize \
  suite_sync_and_sqlite \
  suite_exec_and_storage \
  suite_login_and_doctor \
  suite_shared_repair \
  suite_gate_and_uninstall \
  suite_fastpath_and_remove
do
  run_suite "$_suite"
done

printf 'passed: %s, failed: %s\n' "$total_pass" "$total_fail"
[ "$total_fail" = 0 ]
