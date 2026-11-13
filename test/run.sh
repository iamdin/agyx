#!/bin/sh
# Self-contained tests; uses a fake agy, never the real one.
here=$(cd "$(dirname "$0")/.." && pwd -P)
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
DD=$T/data RH=$T/realhome
mkdir -p "$DD/profiles" "$RH"
export LAUNCHLOG=$T/launched AGYX_DATA_DIR=$DD AGYX_REAL_HOME=$RH HOME=$RH
unset AGY_PROFILE ZDOTDIR BASH_ENV AGYX_ORIG_ZDOTDIR_SET AGYX_ORIG_ZDOTDIR AGYX_ORIG_BASH_ENV_SET AGYX_ORIG_BASH_ENV
# Minimal PATH so the real agy can never be found. $T/brewbin has a Homebrew-style symlink to
# agyx; <data dir>/bin holds the bare `agy` entry (created below by hand to mimic an existing install).
PATH=$T/brewbin:$DD/bin:/usr/bin:/bin:/usr/sbin:/sbin
[ -x "$here/bin/agy" ] && [ -x "$here/bin/agyx" ] || { echo "bin/agy, bin/agyx must be executable" >&2; exit 1; }

cat > "$T/fake-agy" <<'EOF'
#!/bin/sh
[ "$1" = --version ] || echo x >> "$LAUNCHLOG"
FAKE_LOGFILE=; prev=
for a in "$@"; do [ "$prev" = --log-file ] && FAKE_LOGFILE=$a; prev=$a; done
export FAKE_LOGFILE
if [ -n "$FAKE_RUN" ]; then exec sh -c "$FAKE_RUN"; fi
echo "HOME=$HOME"
echo "AGY_PROFILE=$AGY_PROFILE"
echo "ZDOTDIR=${ZDOTDIR-<unset>}"
echo "BASH_ENV=${BASH_ENV-<unset>}"
echo "ORIG_ZDOTDIR=$AGYX_ORIG_ZDOTDIR"
[ "$1" = --log-file ] && echo "LOGFIRST=$2"
skip=0
for a in "$@"; do
  # the shim's own --log-file F is reported on LOGFIRST, not as an ARG
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  if [ "$a" = --log-file ] && [ "$a" = "$1" ]; then skip=1; continue; fi
  echo "ARG=$a"
done
EOF
chmod +x "$T/fake-agy"
# Fake `security`: logs every call (never prints to stdout), keeps a per-HOME default keychain.
cat > "$T/fake-security" <<'EOF'
#!/bin/sh
echo "HOME=$HOME $*" >> "$SECLOG"
if [ "$FAKE_SEC_FAIL" = "$1" ]; then echo "security: fake failure" >&2; exit 1; fi
case $1 in
  create-keychain) mkdir -p "$(dirname "$4")"; : > "$4" ;;
  find-generic-password) [ -f "$HOME/.fake-item" ]; exit $? ;;
  default-keychain)
    if [ "$4" = -s ]; then echo "$5" > "$HOME/.fake-default"
    elif [ -f "$HOME/.fake-default" ]; then echo "    \"$(cat "$HOME/.fake-default")\""
    else echo "    \"$HOME/Library/Keychains/login.keychain-db\""; fi ;;
esac
EOF
chmod +x "$T/fake-security"
export SECLOG=$T/seclog AGYX_SECURITY=$T/fake-security
mkdir "$T/brewbin"; ln -s "$here/bin/agyx" "$T/brewbin/agyx"
mkdir "$DD/bin"; ln -s "$T/fake-agy" "$DD/real-agy"; ln -s "$here/bin/agy" "$DD/bin/agy"
[ "$(command -v agy)" = "$DD/bin/agy" ] || { echo "agy not resolved to $DD/bin/agy" >&2; exit 1; }
for p in work home other; do mkdir -p "$DD/profiles/$p/home"; done
echo work > "$DD/default"
"$here/bin/agyx" profile list >/dev/null 2>&1   # writes the symlinks file once (first-run stderr line)

pass=0 fail=0
eq() { # name expected actual
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3"; fi
}
prof() { agy "$@" | sed -n 's/^AGY_PROFILE=//p'; }
args() { agy "$@" | grep '^ARG='; }
nl='
'

# priority
eq default "work" "$(prof)"
eq env "home" "$(AGY_PROFILE=home prof)"
eq flag-over-env "other" "$(AGY_PROFILE=home prof --profile other)"
eq flag-equals "other" "$(AGY_PROFILE=home prof --profile=other)"
eq home-dir "HOME=$DD/profiles/other/home" "$(agy --profile other | grep ^HOME=)"
eq no-default-file-env-only "home" "$(mv "$DD/default" "$T/d"; AGY_PROFILE=home prof; mv "$T/d" "$DD/default")"

# errors: nonzero, message on stderr, nothing on stdout (never falls back)
bad() { # name args...
  n=$1; shift
  out=$(AGY_PROFILE=work agy "$@" 2>"$T/err"); rc=$?
  eq "err-$n" "nonzero,empty-stdout,has-stderr" \
    "$([ $rc -ne 0 ] && echo nonzero),$([ -z "$out" ] && echo empty-stdout),$([ -s "$T/err" ] && echo has-stderr)"
}
bad missing-value --profile
bad empty-eq --profile=
bad empty-arg --profile ""
bad repeated --profile work --profile other
bad repeated-eq --profile=work --profile=other
bad uppercase --profile Work
bad digit-first --profile 1x
bad too-long --profile abcdefghijklmnopqrstuvwxyzabcdefg
bad bad-chars "--profile=a/b"
bad no-profile-dir --profile nope
bad env-no-dir-fallback --profile nope x
out=$(AGY_PROFILE=BAD agy 2>&1); eq env-invalid "1" "$([ -n "$out" ] && ! echo "$out" | grep -q HOME= && echo 1)"
out=$(AGY_PROFILE=nope agy 2>&1); eq env-no-dir "1" "$([ -n "$out" ] && ! echo "$out" | grep -q HOME= && echo 1)"
mv "$DD/default" "$T/d"
out=$(agy 2>&1); rc=$?
eq no-default "1" "$([ $rc -ne 0 ] && ! echo "$out" | grep -q HOME= && echo 1)"
mv "$T/d" "$DD/default"

# argv preserved
eq argv "ARG=hello world${nl}ARG=${nl}ARG=--profile${nl}ARG=b${nl}ARG=--${nl}ARG=x" \
  "$(args --profile other "hello world" "" --profile b -- x)"
eq dashdash-consumed "ARG=--profile${nl}ARG=b" "$(args --profile other -- --profile b)"
eq dashdash-no-flag "ARG=--profile${nl}ARG=b" "$(AGY_PROFILE=home args -- --profile b)"
eq prompt-profile-untouched "work ARG=-p${nl}ARG=--profile${nl}ARG=zzz" "work $(args -p --profile zzz)"
eq no-args "" "$(args)"

# bridge: run `$1` (shell snippet) inside the shim environment
inshim() { FAKE_RUN=$1 agy --profile other; }
for sh in zsh bash; do
  command -v $sh >/dev/null || { echo "SKIP $sh (not installed)"; continue; }
  eq "$sh-home" "$RH" "$(inshim "$sh -c 'echo \$HOME'")"
  # ZDOTDIR / BASH_ENV come back as unset, empty, or a value
  show="$sh -c 'echo ZD=\${ZDOTDIR-unset}:BE=\${BASH_ENV-unset}'"
  eq "$sh-orig-unset" "ZD=unset:BE=unset" "$(inshim "$show")"
  eq "$sh-orig-empty" "ZD=:BE=" "$(ZDOTDIR='' BASH_ENV='' inshim "$show")"
  eq "$sh-orig-value" "ZD=/zd:BE=/be" "$(ZDOTDIR=/zd BASH_ENV=/be inshim "$show")"
done

# user's own startup files are sourced exactly once
mkdir -p "$T/zd"
echo 'echo x >> "$ZCOUNT"' > "$RH/.zshenv"
echo 'echo x >> "$ZCOUNT"' > "$T/zd/.zshenv"
echo 'echo x >> "$BCOUNT"' > "$T/benv"
export ZCOUNT=$T/zcount BCOUNT=$T/bcount
count() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }
if command -v zsh >/dev/null; then
  : > "$ZCOUNT"; inshim "zsh -c true"; eq zshenv-home-once 1 "$(count "$ZCOUNT")"
  : > "$ZCOUNT"; (ZDOTDIR=$T/zd inshim "zsh -c true"); eq zshenv-zdotdir-once 1 "$(count "$ZCOUNT")"
  eq zshenv-zdotdir-kept "ZD=$T/zd" "$(ZDOTDIR=$T/zd inshim "zsh -c 'echo ZD=\$ZDOTDIR'")"
fi
if command -v bash >/dev/null; then
  : > "$BCOUNT"; (BASH_ENV=$T/benv inshim "bash -c true"); eq bash-env-once 1 "$(count "$BCOUNT")"
  : > "$BCOUNT"; inshim "bash -c true"; eq bash-env-unset-none 0 "$(count "$BCOUNT")"
fi
rm -f "$RH/.zshenv"

# nested: bare agy inside a bridged shell keeps the profile; --profile switches
if command -v zsh >/dev/null; then
  eq nested-same "other" "$(inshim "zsh -c 'FAKE_RUN= agy x'" | sed -n 's/^AGY_PROFILE=//p')"
  eq nested-switch "home" "$(inshim "zsh -c 'FAKE_RUN= agy --profile home x'" | sed -n 's/^AGY_PROFILE=//p')"
  eq nested-home "HOME=$DD/profiles/other/home" "$(inshim "zsh -c 'FAKE_RUN= agy x'" | grep ^HOME=)"
  eq nested-originals "ORIG_ZDOTDIR=/zd" "$(ZDOTDIR=/zd inshim "zsh -c 'FAKE_RUN= agy x'" | grep ^ORIG_ZDOTDIR=)"
fi
# direct nested call (ZDOTDIR/BASH_ENV still point at the bridge): saved originals survive
eq nested-direct "orig-zd=/zd orig-be=/be set=1" "$(ZDOTDIR=$here/runtime/zsh BASH_ENV=$here/runtime/bash_env \
  AGYX_ORIG_ZDOTDIR_SET=1 AGYX_ORIG_ZDOTDIR=/zd AGYX_ORIG_BASH_ENV_SET=1 AGYX_ORIG_BASH_ENV=/be \
  FAKE_RUN='echo orig-zd=$AGYX_ORIG_ZDOTDIR orig-be=$AGYX_ORIG_BASH_ENV set=$AGYX_ORIG_ZDOTDIR_SET' agy --profile home)"

# real-agy pointing at the shim is never used (nor is the shim found on PATH): agy is "not installed"
ln -sfn "$here/bin/agy" "$DD/real-agy"
out=$(agy 2>&1); rc=$?
eq refuse-self "1" "$([ $rc -ne 0 ] && echo "$out" | grep -q 'needs the Antigravity CLI' && ! echo "$out" | grep -q HOME= && echo 1)"
ln -sfn "$T/fake-agy" "$DD/real-agy"

# agyx launches agy unless the first argument is one of its own subcommands
eq launch-flag "other" "$(agyx --profile other | sed -n 's/^AGY_PROFILE=//p')"
eq launch-flag-eq-args "AGY_PROFILE=other${nl}ARG=-p${nl}ARG=hi" "$(agyx --profile=other -p hi | grep '^AGY_PROFILE=\|^ARG=')"
eq launch-env "AGY_PROFILE=home${nl}ARG=--model${nl}ARG=x" "$(AGY_PROFILE=home agyx --model x | grep '^AGY_PROFILE=\|^ARG=')"
eq launch-no-args "AGY_PROFILE=work/0" "$(agyx | grep '^AGY_PROFILE=')/$(agyx | grep -c '^ARG=')"
eq launch-flag-then-subcommand "ARG=mcp${nl}ARG=list" "$(agyx --profile work mcp list | grep '^ARG=')"
eq launch-argv-boundaries "ARG=a b${nl}ARG=${nl}ARG=--profile${nl}ARG=zz" "$(agyx --profile work "a b" "" --profile zz | grep '^ARG=')"
eq launch-help-flags "AGY_PROFILE=other${nl}ARG=--help" "$(agyx --profile other --help | grep '^AGY_PROFILE=\|^ARG=')"
eq project-passthrough "AGY_PROFILE=work${nl}ARG=--project${nl}ARG=x" "$(agyx --project x | grep '^AGY_PROFILE=\|^ARG=')"
eq project-after-profile "AGY_PROFILE=other${nl}ARG=--project${nl}ARG=x" "$(agyx --profile other --project x | grep '^AGY_PROFILE=\|^ARG=')"
eq account-flag-is-plain-arg "AGY_PROFILE=work${nl}ARG=--account${nl}ARG=other" "$(agyx --account other | grep '^AGY_PROFILE=\|^ARG=')"
eq account-eq-is-plain-arg "AGY_PROFILE=work${nl}ARG=--account=other" "$(agyx --account=other | grep '^AGY_PROFILE=\|^ARG=')"
eq escape-dashdash "AGY_PROFILE=home${nl}ARG=foo" "$(AGY_PROFILE=home agyx -- foo | grep '^AGY_PROFILE=\|^ARG=')"
eq launch-umask "$(umask)" "$(FAKE_RUN='umask' agyx --profile other)"
# the old top-level list/login/use are gone: they are ordinary arguments for agy, and valid profile names
eq old-list-passthrough "AGY_PROFILE=work${nl}ARG=list" "$(agyx list | grep '^AGY_PROFILE=\|^ARG=')"
eq old-login-passthrough "AGY_PROFILE=work${nl}ARG=login${nl}ARG=x" "$(agyx login x | grep '^AGY_PROFILE=\|^ARG=')"
eq old-use-passthrough "AGY_PROFILE=work${nl}ARG=use${nl}ARG=x" "$(agyx use x | grep '^AGY_PROFILE=\|^ARG=')"
mkdir -p "$DD/profiles/list/home"
eq profile-named-list "list" "$(agyx --profile list | sed -n 's/^AGY_PROFILE=//p')"
rm -rf "${DD:?}/profiles/list"
# nested calls inside an agent shell route to the inherited profile (agyx, and bare agy when shimmed)
eq nested-agyx "other" "$(FAKE_RUN='FAKE_RUN= agyx x' agyx --profile other | sed -n 's/^AGY_PROFILE=//p')"
eq nested-agy "other" "$(FAKE_RUN='FAKE_RUN= agy x' agyx --profile other | sed -n 's/^AGY_PROFILE=//p')"
eq nested-agyx-switch "home" "$(FAKE_RUN='FAKE_RUN= agyx --profile home x' agyx --profile other | sed -n 's/^AGY_PROFILE=//p')"
# profile names equal to an agyx subcommand are rejected, even if the directory exists
res=
for n in doctor profile uninstall; do
  mkdir -p "$DD/profiles/$n/home"; : > "$LAUNCHLOG"
  agyx --profile "$n" >/dev/null 2>&1 && res="$res launched:$n"
  agy --profile "$n" >/dev/null 2>&1 && res="$res shim-launched:$n"
  "$here/bin/agyx" profile login "$n" >/dev/null 2>&1 && res="$res login:$n"
  "$here/bin/agyx" profile default "$n" >/dev/null 2>&1 && res="$res default:$n"
  [ -s "$LAUNCHLOG" ] && res="$res log:$n"
  rm -rf "${DD:?}/profiles/$n"
done
eq reserved-names "" "$res"

# agyx
ctl() { "$here/bin/agyx" "$@"; }
eq ctl-default "home" "$(ctl profile default home; cat "$DD/default")"
eq ctl-default-bad "1" "$(ctl profile default nope 2>/dev/null || echo 1)"
# list / doctor show the Google account from id_token_email, and never any other token field
tokdir() { mkdir -p "$DD/profiles/$1/home/.gemini/antigravity-cli"; echo "$DD/profiles/$1/home/.gemini/antigravity-cli/antigravity-oauth-token"; }
tokjson() { # profile email  (fake token strings that must never be printed)
  printf '{"token":{"access_token":"SECRET-ACCESS-%s","refresh_token":"SECRET-REFRESH-%s","expiry":"2030-01-01T00:00:00Z"},"auth_method":"oauth","id_token_email":"%s"}\n' "$1" "$1" "$2" > "$(tokdir "$1")"
}
giveitem() { mkdir -p "$DD/profiles/$1/home/Library/Keychains"; : > "$DD/profiles/$1/home/Library/Keychains/login.keychain-db"; : > "$DD/profiles/$1/home/.fake-item"; }
for n in home twin work junk; do giveitem $n; done
printf 'alice@example.com\n' > "$DD/profiles/home/email"; printf 'alice@example.com\n' > "$DD/profiles/twin/email"
dupline="WARNING: profiles home twin are logged in to the same Google account (alice@example.com)"
want=$(printf '%-12s %s\n' home 'alice@example.com  (default)' junk 'logged in, email unknown' other 'not logged in' twin 'alice@example.com' work 'logged in, email unknown')
eq ctl-list "$want${nl}$dupline" "$(ctl profile list)"
eq ctl-doctor-email "1" "$(ctl doctor | grep -c '^profile home: alice@example.com, home ')"
eq ctl-doctor-not-logged-in "1" "$(ctl doctor | grep -c '^profile other: not logged in, home ')"
eq ctl-doctor-unknown "2" "$(ctl doctor | grep -c '^profile \(work\|junk\): logged in, email unknown, home ')"
eq ctl-doctor-dup "1" "$(ctl doctor | grep -cF "$dupline")"
eq ctl-no-token-strings "0" "$( (ctl profile list; ctl doctor) | grep -c SECRET)"
rm -rf "${DD:?}/profiles/twin" "${DD:?}/profiles/junk"
eq ctl-list-no-dup "0" "$(ctl profile list | grep -c WARNING)"
eq ctl-login-bad "1" "$(ctl profile login Bad 2>/dev/null || echo 1)"
eq ctl-login "PROFILE=newp" "$(FAKE_RUN='echo PROFILE=$AGY_PROFILE' ctl profile login newp)"
eq ctl-login-mode "drwx------" "$(ls -ld "$DD/profiles/newp/home" | cut -c1-10)"
# management subcommands never launch agy
: > "$LAUNCHLOG"
for c in "profile list" "profile default work" doctor; do
  # shellcheck disable=SC2086
  agyx $c >/dev/null 2>&1
done
eq mgmt-never-launches "0" "$(wc -c < "$LAUNCHLOG" | tr -d ' ')"
# no profiles yet
mkdir -p "$T/empty"
eq ctl-empty-list "no profiles yet; run: agyx profile login NAME/0" "$(AGYX_DATA_DIR=$T/empty ctl profile list)/$(AGYX_DATA_DIR=$T/empty ctl profile list >/dev/null; echo $?)"
# misuse of a management subcommand prints the usage (exit 2) and never launches agy
: > "$LAUNCHLOG"
res=
for c in profile "profile bogus" "profile login" "profile login Bad" "profile login profile" "profile login a b" "profile default a b" "profile default nope" "profile default profile" "profile list x" "doctor x" "uninstall x"; do
  # shellcheck disable=SC2086
  out=$(ctl $c 2>&1 >/dev/null); rc=$?
  [ "$rc" = 2 ] && echo "$out" | grep -q '^usage: agyx' || res="$res [$c rc=$rc]"
done
eq ctl-misuse-usage "" "$res"
eq ctl-misuse-no-launch "0" "$(wc -c < "$LAUNCHLOG" | tr -d ' ')"
# the removed commands are ordinary arguments for agy now, and valid profile names
for c in setup shim unshim; do
  eq "removed-$c" "AGY_PROFILE=work${nl}ARG=$c" "$(agyx "$c" | grep '^AGY_PROFILE=\|^ARG=')"
  mkdir -p "$DD/profiles/$c/home"
  eq "profile-named-$c" "$c" "$(agyx --profile "$c" | sed -n 's/^AGY_PROFILE=//p')"
  rm -rf "${DD:?}/profiles/$c"
done
eq usage-lists-only-current "0" "$(ctl profile 2>&1 | grep -c 'setup\|shim')"

# agyx subcommands never overlap with the real agy 1.5.6 subcommands/flags
ctl_subs="doctor profile uninstall"
agy_subs="acp agent agents changelog install mcp mic-serve models plugin plugins remote-control update"
both=
for a in $ctl_subs; do for b in $agy_subs; do [ "$a" = "$b" ] && both="$both $a"; done; done
eq subcommands-disjoint "" "$both"
eq subcommands-match-script "$ctl_subs" "$(sed -n 's/^  case \$1 in \(.*\)) return 0 ;; esac$/\1/p' "$here/runtime/sync.sh" | tr '|' ' ')"
res=
for s in $agy_subs; do [ "$(agyx "$s" | grep '^ARG=')" = "ARG=$s" ] || res="$res $s"; done
eq agy-subcommands-reach-agy "" "$res"
# names of agy subcommands are fine as profile names
mkdir -p "$DD/profiles/install/home"
eq profile-named-install "install" "$(agyx --profile install | sed -n 's/^AGY_PROFILE=//p')"
rm -rf "${DD:?}/profiles/install"

# doctor
eq ctl-doctor-path "1" "$(ctl doctor | grep -c 'agyx resolves to this script')"
eq ctl-doctor-path-missing "1" "$(PATH=/usr/bin:/bin ctl doctor | grep -c 'agyx does NOT resolve')"
eq ctl-doctor-real "1" "$(ctl doctor | grep -c "^real agy: $T/fake-agy\$")"
eq ctl-doctor-entry "1" "$(ctl doctor | grep -c "^agy entry: $DD/bin/agy (in place; the path to give apps that need a binary named agy)\$")"
eq ctl-doctor-no-takeover "0" "$(ctl doctor | grep -ci 'takeover\|unshim\|agyx shim\|agyx setup')"

# ---- automatic setup (fresh data dir and real home each time; there is no setup command) ----
islink() { [ -L "$1" ] && [ "$1" -ef "$2" ] && echo link || echo "not-link"; }
fresh() { N=$T/$1; rm -rf "$N"; mkdir -p "$N/rh" "$N/data/profiles/p/home"; }
fx() { env AGYX_DATA_DIR="$N/data" AGYX_REAL_HOME="$N/rh" "$@"; }
AX=$here/bin/agyx
rm -rf "$T/fakebin"; mkdir "$T/fakebin"; ln -s "$T/fake-agy" "$T/fakebin/agy"
SP=$T/fakebin:/usr/bin:/bin
# real agy: found on PATH (skipping agyx's own entry), stored, then no PATH needed
fresh a1; mkdir -p "$N/data/bin"; ln -s "$here/bin/agy" "$N/data/bin/agy"
out=$(fx env PATH="$N/data/bin:$SP" "$AX" --profile p 2>/dev/null)
eq auto-real-found "AGY_PROFILE=p" "$(echo "$out" | grep '^AGY_PROFILE=')"
eq auto-real-stored "$T/fakebin/agy" "$(readlink "$N/data/real-agy")"
eq auto-real-steady "AGY_PROFILE=p" "$(fx env PATH=/usr/bin:/bin "$AX" --profile p 2>/dev/null | grep '^AGY_PROFILE=')"
# a stored link that no longer works is searched again
ln -sfn "$T/gone-agy" "$N/data/real-agy"
eq auto-real-refound "AGY_PROFILE=p/$T/fakebin/agy" "$(fx env PATH="$SP" "$AX" --profile p 2>/dev/null | grep '^AGY_PROFILE=')/$(readlink "$N/data/real-agy")"
# a relative PATH entry is stored absolute
fresh a2; ( cd "$T" && fx env PATH="fakebin:/usr/bin:/bin" "$AX" --profile p >/dev/null 2>&1 )
eq auto-real-relative-path "$T/fakebin/agy" "$(readlink "$N/data/real-agy")"
# AGYX_REAL_AGY overrides everything and is not stored
fresh a3
out=$(fx env PATH=/usr/bin:/bin AGYX_REAL_AGY="$T/fake-agy" "$AX" --profile p 2>/dev/null)
eq override-used "AGY_PROFILE=p" "$(echo "$out" | grep '^AGY_PROFILE=')"
eq override-not-stored "absent" "$([ -e "$N/data/real-agy" ] || [ -L "$N/data/real-agy" ] || echo absent)"
ln -s "$T/gone-agy" "$N/data/real-agy"
eq override-beats-stored "AGY_PROFILE=p" "$(fx env AGYX_REAL_AGY="$T/fake-agy" "$AX" --profile p 2>/dev/null | grep '^AGY_PROFILE=')"
n=0
for badv in "$T/nonexistent" "$here/bin/agy" "$T"; do
  n=$((n + 1)); : > "$LAUNCHLOG"
  out=$(fx env PATH="$SP" AGYX_REAL_AGY="$badv" "$AX" --profile p 2>"$T/err"); rc=$?
  eq "override-bad-$n" "nonzero,empty,AGYX_REAL_AGY,0" "$([ $rc -ne 0 ] && echo nonzero),$([ -z "$out" ] && echo empty),$(grep -o AGYX_REAL_AGY "$T/err" | head -n 1),$(wc -c < "$LAUNCHLOG" | tr -d ' ')"
done
# not installed: clear message, nothing on stdout, nothing stored
fresh a4
out=$(fx env PATH=/usr/bin:/bin "$AX" --profile p 2>"$T/err"); rc=$?
eq not-installed "nonzero,empty,not-installed,how-to" "$([ $rc -ne 0 ] && echo nonzero),$([ -z "$out" ] && echo empty),$(grep -q 'needs the Antigravity CLI' "$T/err" && echo not-installed),$(grep -q 'AGYX_REAL_AGY=/path/to/agy' "$T/err" && echo how-to)"
eq not-installed-nothing-stored "absent" "$([ -e "$N/data/real-agy" ] || [ -L "$N/data/real-agy" ] || echo absent)"
# <data>/bin/agy: created on launch, profile and doctor runs; a dangling link is replaced
for c in "--profile p" "profile list" doctor; do
  fresh a5
  # shellcheck disable=SC2086
  fx env PATH="$SP" "$AX" $c >/dev/null 2>&1
  eq "entry-created-$c" "$here/bin/agy" "$(readlink "$N/data/bin/agy")"
done
rm "$N/data/bin/agy"; ln -s "$T/gone-agy" "$N/data/bin/agy"
fx env PATH="$SP" "$AX" doctor >/dev/null 2>&1
eq entry-dangling-replaced "$here/bin/agy" "$(readlink "$N/data/bin/agy")"
echo mine > "$N/x"; rm "$N/data/bin/agy"; ln -s "$N/x" "$N/data/bin/agy"
eq entry-existing-kept "$N/x" "$(fx env PATH="$SP" "$AX" doctor >/dev/null 2>&1; readlink "$N/data/bin/agy")"
eq entry-doctor-flags-foreign "1" "$(fx env PATH="$SP" "$AX" doctor 2>&1 | grep -c '^agy entry: .*MISSING or not agyx')"
# the entry works as a bare agy
fresh a6; fx env PATH="$SP" "$AX" doctor >/dev/null 2>&1
eq entry-runs-agy "AGY_PROFILE=p" "$(fx env PATH="$SP" "$N/data/bin/agy" --profile p 2>/dev/null | grep '^AGY_PROFILE=')"
# symlinks file: written on the first run (one stderr line, nothing extra on stdout), default list inside
fresh a7
out=$(fx env PATH="$SP" "$AX" --profile p 2>"$T/err")
eq links-first-stderr "1/1" "$(grep -c . "$T/err")/$(grep -c "^agyx: wrote $N/rh/.config/agyx/symlinks " "$T/err")"
eq links-first-stdout "0" "$(echo "$out" | grep -c wrote)"
eq links-content ".gitconfig .ssh .config .npm .npmrc .bun .bunfig.toml .cache .cargo .rustup go Code GitHub " "$(grep -v '^#' "$N/rh/.config/agyx/symlinks" | tr '\n' ' ')"
eq links-header "2" "$(grep -c '^#' "$N/rh/.config/agyx/symlinks")"
fx env PATH="$SP" "$AX" --profile p >/dev/null 2>"$T/err"
eq links-second-silent "0" "$(grep -c . "$T/err")"
echo mine > "$N/rh/.config/agyx/symlinks"
fx env PATH="$SP" "$AX" --profile p >/dev/null 2>&1
eq links-never-overwritten "mine" "$(cat "$N/rh/.config/agyx/symlinks")"
# unwritable: no message, the built-in default list still applies, doctor says so
fresh a8; echo notadir > "$N/rh/.config"; echo gc > "$N/rh/.gitconfig"
fx env FAKE_RUN=true PATH="$SP" "$AX" --profile p >/dev/null 2>"$T/err"; rc=$?
eq links-unwritable "0/0/link" "$rc/$(grep -c . "$T/err")/$(islink "$N/data/profiles/p/home/.gitconfig" "$N/rh/.gitconfig")"
eq links-unwritable-doctor "1" "$(fx env PATH="$SP" "$AX" doctor 2>&1 | grep -c '^symlinks: .*missing and could not be written')"
# launch path: nothing on stdout from agyx itself
fresh a9
eq launch-stdout-clean "" "$(fx env FAKE_RUN=true PATH="$SP" "$AX" --profile p 2>/dev/null)"
# first-run messages: nonzero, nothing on stdout, nothing launched
fresh b1; rmdir "$N/data/profiles/p/home" "$N/data/profiles/p"
: > "$LAUNCHLOG"
out=$(fx env PATH="$SP" "$AX" 2>"$T/err"); rc=$?
eq first-none "nonzero,empty,msg,0" "$([ $rc -ne 0 ] && echo nonzero),$([ -z "$out" ] && echo empty),$(grep -q 'no profiles yet' "$T/err" && grep -q 'agyx profile login NAME' "$T/err" && grep -q 'for example' "$T/err" && echo msg),$(wc -c < "$LAUNCHLOG" | tr -d ' ')"
fresh b2; mkdir -p "$N/data/profiles/q/home"
out=$(fx env PATH="$SP" "$AX" 2>"$T/err"); rc=$?
eq first-no-default "nonzero,empty,msg" "$([ $rc -ne 0 ] && echo nonzero),$([ -z "$out" ] && echo empty),$(grep -q 'Existing profiles: p q' "$T/err" && grep -q -e '--profile NAME' "$T/err" && grep -q 'agyx profile default NAME' "$T/err" && echo msg)"
echo gone > "$N/data/default"
out=$(fx env PATH="$SP" "$AX" 2>"$T/err"); rc=$?
eq first-default-missing "nonzero,empty,msg" "$([ $rc -ne 0 ] && echo nonzero),$([ -z "$out" ] && echo empty),$(grep -q "default profile 'gone'.*does not exist" "$T/err" && grep -q 'agyx profile default NAME' "$T/err" && grep -q 'agyx profile login gone' "$T/err" && echo msg)"
echo p > "$N/data/default"
eq not-logged-in-launches "AGY_PROFILE=p" "$(fx env PATH="$SP" "$AX" 2>/dev/null | grep '^AGY_PROFILE=')"
# profile login: the first successful login becomes the default
fresh c1; rmdir "$N/data/profiles/p/home" "$N/data/profiles/p"
mktok='touch $HOME/.fake-item'
out=$(fx env FAKE_RUN="$mktok" PATH="$SP" "$AX" profile login first 2>"$T/err"); rc=$?
eq login-sets-default "0/first/1" "$rc/$(cat "$N/data/default")/$(echo "$out" | grep -c "'first' is now the default profile")"
fx env FAKE_RUN="$mktok" PATH="$SP" "$AX" profile login second >/dev/null 2>&1
eq login-keeps-existing-default "first" "$(cat "$N/data/default")"
out=$(fx env FAKE_RUN=true PATH="$SP" "$AX" profile login first 2>"$T/err")
eq login-already-logged-in "1/0" "$(grep -c 'already logged in' "$T/err")/$(echo "$out" | grep -c .)"
fresh c2; rmdir "$N/data/profiles/p/home" "$N/data/profiles/p"
out=$(fx env FAKE_RUN=true PATH="$SP" "$AX" profile login nologin 2>/dev/null); rc=$?
eq login-without-login-no-default "0/absent/" "$rc/$([ -e "$N/data/default" ] || echo absent)/$out"
fx env FAKE_RUN='exit 3' PATH="$SP" "$AX" profile login failed >/dev/null 2>&1; rc=$?
eq login-failed-rc-no-default "3/absent" "$rc/$([ -e "$N/data/default" ] || echo absent)"
# login detected through the profile keychain item too
fx env FAKE_RUN='touch $HOME/.fake-item' PATH="$SP" "$AX" profile login viakc >/dev/null 2>&1
eq login-keychain-sets-default "viakc" "$(cat "$N/data/default" 2>/dev/null)"

# ---- ask once before the first write (data dir absent = not set up) ----
gfresh() { N=$T/$1; rm -rf "$N"; mkdir -p "$N/rh"; }
nothing_written() { [ ! -e "$N/data" ] && [ ! -e "$N/rh/.config" ] && echo yes || echo no; }
for c in "--profile p" "profile login p" "profile default p"; do
  gfresh g1; : > "$LAUNCHLOG"
  # shellcheck disable=SC2086
  out=$(fx env PATH="$SP" "$AX" $c 2>"$T/err" </dev/null); rc=$?
  eq "gate-noterm-$c" "nonzero,empty,1,msg,yes,0" "$([ $rc -ne 0 ] && echo nonzero),$([ -z "$out" ] && echo empty),$(grep -c . "$T/err"),$(grep -q 'not set up yet.*once in a terminal.*AGYX_ASSUME_YES=1' "$T/err" && echo msg),$(nothing_written),$(wc -c < "$LAUNCHLOG" | tr -d ' ')"
done
# read-only commands never ask and never create anything
for c in doctor "profile list" "profile default"; do
  gfresh g2
  # shellcheck disable=SC2086
  out=$(fx env PATH="$SP" "$AX" $c 2>"$T/err" </dev/null); rc=$?
  eq "gate-readonly-$c" "0,notyet,empty-err,yes" "$rc,$(echo "$out" | grep -c 'not set up yet' | sed 's/1/notyet/'),$([ -s "$T/err" ] || echo empty-err),$(nothing_written)"
done
# AGYX_ASSUME_YES=1 skips the question
gfresh g3
out=$(fx env PATH="$SP" AGYX_ASSUME_YES=1 FAKE_RUN="$mktok" "$AX" profile login w 2>"$T/err" </dev/null)
eq gate-assume-yes "w/$here/bin/agy/present/1" "$(cat "$N/data/default")/$(readlink "$N/data/bin/agy")/$([ -f "$N/rh/.config/agyx/symlinks" ] && echo present)/$(grep -c 'Continue' "$T/err" | sed 's/0/1/')"
# the prompt: answers come from AGYX_TTY (tests only); yes, empty line (default yes), no, EOF
printf 'y\n' > "$T/ans-y"; printf '\n' > "$T/ans-enter"; printf 'n\n' > "$T/ans-n"; : > "$T/ans-eof"
for a in y enter; do
  gfresh g4
  out=$(fx env PATH="$SP" AGYX_TTY="$T/ans-$a" FAKE_RUN="$mktok" "$AX" profile login w 2>"$T/err" </dev/null); rc=$?
  eq "gate-prompt-$a" "0/w/$here/bin/agy/present" "$rc/$(cat "$N/data/default" 2>/dev/null)/$(readlink "$N/data/bin/agy")/$([ -f "$N/rh/.config/agyx/symlinks" ] && echo present)"
done
eq gate-prompt-text-outside-home "agyx will set up:|  $N/data/  profiles (one HOME and keychain per account), a link to agy at $T/fakebin/agy|  $N/data/bin/agy  entry for apps that need a binary named agy|  ~/.config/agyx/symlinks  home entries linked into every profile (editable)|Profiles share your ~/.gemini settings and history; your login keychain is not touched.|Continue? [Y/n] " "$(sed -n '/^agyx will set up/,/Continue/p' "$T/err" | tr '\n' '|' | sed -e 's/|$//' -e 's/Continue.*/Continue? [Y\/n] /')"
# inside the real home the notice shows ~/...
gfresh g4h; mkdir -p "$N/rh/.local/bin"; ln -s "$T/fake-agy" "$N/rh/.local/bin/agy"
env -u AGYX_DATA_DIR AGYX_REAL_HOME="$N/rh" PATH="$N/rh/.local/bin:/usr/bin:/bin" AGYX_TTY="$T/ans-n" "$AX" --profile p </dev/null 2>"$T/err"
eq gate-prompt-text-home "agyx will set up:|  ~/.local/share/agyx/  profiles (one HOME and keychain per account), a link to agy at ~/.local/bin/agy|  ~/.local/share/agyx/bin/agy  entry for apps that need a binary named agy|  ~/.config/agyx/symlinks  home entries linked into every profile (editable)|Profiles share your ~/.gemini settings and history; your login keychain is not touched.|Continue? [Y/n] " "$(sed -n '/^agyx will set up/,/Continue/p' "$T/err" | tr '\n' '|' | sed -e 's/|$//' -e 's/Continue.*/Continue? [Y\/n] /')"
eq gate-prompt-continues "1" "$(echo "$out" | grep -c "'w' is now the default profile")"
for a in n eof; do
  gfresh g5; : > "$LAUNCHLOG"
  out=$(fx env PATH="$SP" AGYX_TTY="$T/ans-$a" "$AX" --profile p 2>"$T/err" </dev/null); rc=$?
  eq "gate-prompt-$a" "nonzero,empty,yes,0" "$([ $rc -ne 0 ] && echo nonzero),$([ -z "$out" ] && echo empty),$(nothing_written),$(wc -c < "$LAUNCHLOG" | tr -d ' ')"
done
# an existing data dir is never asked
fresh g6
eq gate-existing-not-asked "AGY_PROFILE=p/0" "$(fx env PATH="$SP" AGYX_TTY="$T/ans-n" "$AX" --profile p 2>"$T/err" </dev/null | grep '^AGY_PROFILE=')/$(grep -c 'Continue' "$T/err")"
# after setup, repairs are silent
rm -f "$N/data/bin/agy"; : > "$T/err"
fx env PATH="$SP" AGYX_TTY="$T/ans-n" "$AX" doctor >/dev/null 2>"$T/err" </dev/null
eq gate-repair-silent "present/0" "$([ -L "$N/data/bin/agy" ] && echo present)/$(grep -c . "$T/err")"

# ---- Homebrew layout: Cellar paths map to the stable opt path; the entry link is repointed ----
ver=$(sed -n 's/^AGYX_VERSION=\([0-9.]*\).*/\1/p' "$here/runtime/sync.sh")
brewlayout() { # prefix version: a Cellar install with the opt link and bin link, as Homebrew makes it
  mkdir -p "$1/Cellar/agyx/$2/libexec" "$1/bin" "$1/opt"
  cp -R "$here/bin" "$here/runtime" "$1/Cellar/agyx/$2/libexec/"
  ln -sfn "../Cellar/agyx/$2" "$1/opt/agyx"
  ln -sfn "../Cellar/agyx/$2/libexec/bin/agyx" "$1/bin/agyx"
}
ustable() { ( . "$here/runtime/sync.sh"; agyx_stable "$1"; printf %s "$AGYX_STABLE" ); }
TP=$(cd "$T" && pwd -P); HB=$TP/hb; brewlayout "$HB" 0.1.0
eq stable-cellar-mapped "$HB/opt/agyx/libexec/bin/agy" "$(ustable "$HB/Cellar/agyx/0.1.0/libexec/bin/agy")"
eq stable-cellar-no-opt "$T/nope/Cellar/agyx/0.1.0/libexec/bin/agy" "$(ustable "$T/nope/Cellar/agyx/0.1.0/libexec/bin/agy")"
eq stable-checkout-kept "$here/bin/agy" "$(ustable "$here/bin/agy")"
eq stable-other-cellar-formula-kept "$HB/Cellar/agyxfoo/1/bin/agy" "$(ustable "$HB/Cellar/agyxfoo/1/bin/agy")"
fresh h1; mkdir -p "$N/data/bin"
out=$(fx env PATH=/usr/bin:/bin AGYX_REAL_AGY="$T/fake-agy" FAKE_RUN='echo ZD=$ZDOTDIR; echo BE=$BASH_ENV' "$HB/bin/agyx" --profile p 2>/dev/null </dev/null)
eq cellar-entry-opt "$HB/opt/agyx/libexec/bin/agy" "$(readlink "$N/data/bin/agy")"
eq cellar-zdotdir-bashenv "ZD=$HB/opt/agyx/libexec/runtime/zsh${nl}BE=$HB/opt/agyx/libexec/runtime/bash_env" "$out"
eq cellar-doctor-entry-ok "1" "$(fx env PATH=/usr/bin:/bin "$HB/bin/agyx" doctor </dev/null 2>&1 | grep -c "^agy entry: $N/data/bin/agy (in place")"
# an upgrade replaces the Cellar directory and the opt link; the stored paths keep working
brewlayout "$HB" 0.2.0; rm -rf "${HB:?}/Cellar/agyx/0.1.0"
eq upgrade-entry-still-works "AGY_PROFILE=p" "$(fx env PATH=/usr/bin:/bin AGYX_REAL_AGY="$T/fake-agy" "$N/data/bin/agy" --profile p 2>/dev/null </dev/null | grep '^AGY_PROFILE=')"
eq upgrade-link-unchanged "$HB/opt/agyx/libexec/bin/agy" "$(readlink "$N/data/bin/agy")"
# a link to an old Cellar location (as an older agyx stored it) is repointed on any run
rm "$N/data/bin/agy"; mkdir -p "$T/oldcell/Cellar/agyx/0.0.9/libexec"; cp -R "$here/bin" "$here/runtime" "$T/oldcell/Cellar/agyx/0.0.9/libexec/"
ln -s "$T/oldcell/Cellar/agyx/0.0.9/libexec/bin/agy" "$N/data/bin/agy"
fx env PATH=/usr/bin:/bin "$HB/bin/agyx" profile list >/dev/null 2>&1 </dev/null
eq repoint-other-agyx "$HB/opt/agyx/libexec/bin/agy" "$(readlink "$N/data/bin/agy")"
# ... a dangling link too
rm "$N/data/bin/agy"; ln -s "$T/oldcell/Cellar/agyx/0.0.1/libexec/bin/agy" "$N/data/bin/agy"
fx env PATH=/usr/bin:/bin AGYX_REAL_AGY="$T/fake-agy" "$HB/bin/agyx" --profile p >/dev/null 2>&1 </dev/null
eq repoint-dangling "$HB/opt/agyx/libexec/bin/agy" "$(readlink "$N/data/bin/agy")"
# ... but a link that is not an agyx entry stays (a file named agy without agyx's runtime beside it, a file)
mkdir -p "$T/notagyx/bin"; echo x > "$T/notagyx/bin/agy"
rm "$N/data/bin/agy"; ln -s "$T/notagyx/bin/agy" "$N/data/bin/agy"
fx env PATH=/usr/bin:/bin "$HB/bin/agyx" profile list >/dev/null 2>&1 </dev/null
eq no-repoint-foreign-link "$T/notagyx/bin/agy" "$(readlink "$N/data/bin/agy")"
rm "$N/data/bin/agy"; echo mine > "$N/data/bin/agy"
fx env PATH=/usr/bin:/bin "$HB/bin/agyx" profile list >/dev/null 2>&1 </dev/null
eq no-repoint-regular-file "mine" "$(cat "$N/data/bin/agy")"
# a Cellar install without an opt link keeps the resolved path
HC=$TP/hc; brewlayout "$HC" 0.1.0; rm "$HC/opt/agyx"
fresh h2
fx env PATH=/usr/bin:/bin "$HC/bin/agyx" profile list >/dev/null 2>&1 </dev/null
eq cellar-without-opt-kept "$HC/Cellar/agyx/0.1.0/libexec/bin/agy" "$(readlink "$N/data/bin/agy")"
# version: one place, shown by --version and doctor
eq version-one-place "1" "$(grep -rl '^AGYX_VERSION=' "$here/bin" "$here/runtime" "$here/Formula" | wc -l | tr -d ' ')"
eq version-format "yes" "$(echo "$ver" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' && echo yes)"
eq version-formula-tag "1" "$(grep -c "archive/refs/tags/v$ver.tar.gz" "$here/Formula/agyx.rb")"
fresh v1
out=$(fx env PATH="$SP" "$AX" --version </dev/null 2>&1)
eq version-both "agyx $ver/agy" "$(echo "$out" | sed -n 1p)/$(echo "$out" | sed -n 2p | cut -d' ' -f1)"
eq version-writes-nothing "yes" "$(rm -rf "$N/data"; fx env PATH="$SP" "$AX" --version >/dev/null 2>&1 </dev/null; [ ! -e "$N/data" ] && [ ! -e "$N/rh/.config" ] && echo yes)"
eq version-no-agy "agyx $ver" "$(fx env PATH=/usr/bin:/bin "$AX" --version </dev/null 2>&1)"
eq version-override "agyx $ver/agy" "$(fx env PATH=/usr/bin:/bin AGYX_REAL_AGY="$T/fake-agy" "$AX" --version </dev/null 2>&1 | tr '\n' / | cut -d/ -f1)/$(fx env AGYX_REAL_AGY="$T/fake-agy" "$AX" --version </dev/null 2>&1 | sed -n 2p | cut -d' ' -f1)"
fresh v2
eq version-doctor "agyx version: $ver" "$(fx env PATH="$SP" "$AX" doctor </dev/null 2>/dev/null | sed -n 1p)"
eq version-doctor-before-setup "agyx version: $ver" "$(rm -rf "$N/data"; fx env PATH="$SP" "$AX" doctor </dev/null 2>/dev/null | sed -n 1p)"

# ---- help forms and the missing-agy message (0.1.1) ----
# agyx --help / -h / help: agyx's own usage; read-only, never asks, works before setup
for h in --help -h help; do
  gfresh h1; : > "$LAUNCHLOG"
  out=$(fx env PATH=/usr/bin:/bin AGYX_TTY="$T/ans-y" "$AX" "$h" 2>"$T/err" </dev/null); rc=$?
  eq "help-$h" "0,usage,agy-help-line,empty-err,yes,0" "$rc,$(echo "$out" | grep -c '^usage: agyx' | sed 's/1/usage/'),$(echo "$out" | grep -qF "any other arguments go to agy; agy's own help: agyx --profile NAME --help" && echo agy-help-line),$([ -s "$T/err" ] || echo empty-err),$(nothing_written),$(wc -c < "$LAUNCHLOG" | tr -d ' ')"
done
fresh h2; : > "$LAUNCHLOG"
eq help-after-setup-no-launch "usage/0" "$(fx env PATH="$SP" "$AX" --help </dev/null 2>&1 | grep -c '^usage: agyx' | sed 's/1/usage/')/$(wc -c < "$LAUNCHLOG" | tr -d ' ')"
# with a chosen profile --help still goes to agy
eq help-profile-passthrough "AGY_PROFILE=p${nl}ARG=--help" "$(fx env PATH="$SP" "$AX" --profile p --help </dev/null 2>/dev/null | grep '^AGY_PROFILE=\|^ARG=')"
eq help-extra-args-to-agy "AGY_PROFILE=p${nl}ARG=-h${nl}ARG=x" "$(fx env PATH="$SP" AGY_PROFILE=p "$AX" -h x </dev/null 2>/dev/null | grep '^AGY_PROFILE=\|^ARG=')"
# agy not installed: no prompt, nothing written, the message, nonzero; for every writing command
msgwant="agyx: agyx needs the Antigravity CLI (agy) first, and it is not installed.${nl}Install it with the official command:  curl -fsSL https://antigravity.google/cli/install.sh | bash${nl}(docs: https://antigravity.google/docs/cli/overview)${nl}Then run agyx again. If agy is installed somewhere else, set AGYX_REAL_AGY=/path/to/agy."
for c in "--profile p" "profile login p" "profile default p"; do
  for mode in tty assume noterm; do
    gfresh h3; : > "$LAUNCHLOG"
    case $mode in
      tty) e="AGYX_TTY=$T/ans-y" ;; assume) e="AGYX_ASSUME_YES=1" ;; noterm) e="X=1" ;;
    esac
    # shellcheck disable=SC2086
    out=$(fx env PATH=/usr/bin:/bin $e "$AX" $c 2>"$T/err" </dev/null); rc=$?
    eq "noagy-$mode-$c" "nonzero,empty,msg,no-prompt,yes,0" "$([ $rc -ne 0 ] && echo nonzero),$([ -z "$out" ] && echo empty),$([ "$(cat "$T/err")" = "$msgwant" ] && echo msg),$(grep -q 'Continue\|will set up' "$T/err" || echo no-prompt),$(nothing_written),$(wc -c < "$LAUNCHLOG" | tr -d ' ')"
  done
done
# set up already but no agy: same message (launch and profile login)
for c in "--profile p" "profile login p"; do
  fresh h4
  out=$(fx env PATH=/usr/bin:/bin "$AX" $c 2>"$T/err" </dev/null); rc=$?
  eq "noagy-setup-$c" "nonzero,empty,msg" "$([ $rc -ne 0 ] && echo nonzero),$([ -z "$out" ] && echo empty),$([ "$(tail -n 4 "$T/err")" = "$msgwant" ] && echo msg)"
done
# the override pointing at something unusable keeps its own message (before setup, nothing written)
gfresh h5
out=$(fx env PATH="$SP" AGYX_ASSUME_YES=1 AGYX_REAL_AGY="$T/nonexistent" "$AX" --profile p 2>"$T/err" </dev/null); rc=$?
eq noagy-bad-override "nonzero,empty,yes,1" "$([ $rc -ne 0 ] && echo nonzero),$([ -z "$out" ] && echo empty),$(nothing_written),$(grep -c 'AGYX_REAL_AGY=.*is not an executable file' "$T/err")"
# the notice no longer has a "not found yet" branch
eq no-not-found-yet "0" "$(grep -c 'not found yet' "$here/runtime/sync.sh")"

# per-profile keychain (fake security; the real one is never called)
H=$DD/profiles/kc/home K=$DD/profiles/kc/home/Library/Keychains/login.keychain-db
mkdir -p "$H"; : > "$SECLOG"
out=$(agyx --profile kc x)
eq kc-stdout-only-agy "7" "$(echo "$out" | wc -l | tr -d ' ')"
eq kc-exact-calls "$(printf 'HOME=%s create-keychain -p  %s\nHOME=%s list-keychains -d user -s %s\nHOME=%s default-keychain -d user -s %s\nHOME=%s set-keychain-settings %s' "$H" "$K" "$H" "$K" "$H" "$K" "$H" "$K")" "$(cat "$SECLOG")"
eq kc-dir-modes "drwx------ drwx------" "$(ls -ld "$H/Library" "$H/Library/Keychains" | cut -c1-10 | tr '\n' ' ' | sed 's/ $//')"
: > "$SECLOG"; agyx --profile kc x >/dev/null
eq kc-second-launch-no-calls "0" "$(wc -c < "$SECLOG" | tr -d ' ')"
# failing security only warns; agy still launches; a later launch retries
mkdir -p "$DD/profiles/kcfail/home"
out=$(FAKE_SEC_FAIL=create-keychain agyx --profile kcfail y 2>"$T/err")
eq kc-fail-launches "ARG=y" "$(echo "$out" | grep '^ARG=')"
eq kc-fail-warns "1" "$(grep -c 'warning: could not create the profile keychain' "$T/err")"
eq kc-fail-no-keychain "absent" "$([ -e "$DD/profiles/kcfail/home/Library/Keychains/login.keychain-db" ] || echo absent)"
out=$(FAKE_SEC_FAIL=default-keychain agyx --profile kcfail y 2>/dev/null)
eq kc-fail-late-step-launches "ARG=y" "$(echo "$out" | grep '^ARG=')"
eq kc-fail-late-step-removed "absent" "$([ -e "$DD/profiles/kcfail/home/Library/Keychains/login.keychain-db" ] || echo absent)"
agyx --profile kcfail y >/dev/null
eq kc-retried "present" "$([ -e "$DD/profiles/kcfail/home/Library/Keychains/login.keychain-db" ] && echo present)"
# doctor
mkdir -p "$DD/profiles/nokc/home" "$DD/profiles/badkc/home"
agyx --profile badkc z >/dev/null; echo /elsewhere > "$DD/profiles/badkc/home/.fake-default"
eq kc-doctor-ok "1" "$(ctl doctor | grep -c '^profile kc: .*keychain ok (default for this profile)$')"
eq kc-doctor-missing "1" "$(ctl doctor | grep -c '^profile nokc: .*keychain missing (created on next launch)$')"
eq kc-doctor-not-default "1" "$(ctl doctor | grep -c '^profile badkc: .*keychain NOT the default for this profile (found: /elsewhere)$')"
eq kc-doctor-real-ok "1" "$(ctl doctor | grep -c "^keychain: real default keychain is $RH/Library/Keychains/login.keychain-db, outside the agyx data dir$")"
echo "$DD/profiles/kc/home/Library/Keychains/login.keychain-db" > "$RH/.fake-default"
eq kc-doctor-real-inside "1" "$(ctl doctor | grep -c '^keychain: WARNING the real default keychain is inside the agyx data dir')"
rm -f "$RH/.fake-default"
eq kc-doctor-no-secrets "0" "$(ctl doctor | grep -c SECRET)"
# every write call went to a profile HOME with an explicit keychain path; never the real HOME
eq kc-never-real-keychain "0" "$(grep -e ' -s ' -e create-keychain -e set-keychain-settings "$SECLOG" | grep -vc "^HOME=$DD/profiles/[a-z]*/home .*$DD/profiles/[a-z]*/home/Library/Keychains/login.keychain-db")"
rm -rf "${DD:?}/profiles/kc" "${DD:?}/profiles/kcfail" "${DD:?}/profiles/nokc" "${DD:?}/profiles/badkc"

# ---- shared ~/.gemini and home whitelist ----
G=$RH/.gemini
launch() { FAKE_RUN=true agyx --profile "$1" 2>"$T/err"; }
islink() { [ -L "$1" ] && [ "$1" -ef "$2" ] && echo link || echo "not-link"; }
# the per-launch log files change on every launch and are not part of what the snapshots compare
snap() { find "$@" \( -path '*/log/cli-*.log' -o -path '*/profiles/*/cli.log' \) -delete 2>/dev/null; ls -lRA "$@"; }
mkdir -p "$G/antigravity-cli"
# whitelist: default list when symlinks is missing
HL=$RH/.config/agyx/symlinks   # the whitelist file lives in the real home's config dir
rm -f "$HL"
mkdir -p "$RH/.ssh" "$RH/.config"; echo gc > "$RH/.gitconfig"
S4=$DD/profiles/s4/home; mkdir -p "$S4/.ssh"; echo mine > "$S4/.ssh/x"; ln -s /elsewhere "$S4/.config"
launch s4 >/dev/null
eq wl-default-link "link" "$(islink "$S4/.gitconfig" "$RH/.gitconfig")"
eq wl-conflict-dir "mine" "$(cat "$S4/.ssh/x")"
eq wl-conflict-dir-not-link "no" "$([ -L "$S4/.ssh" ] && echo yes || echo no)"
eq wl-conflict-link "/elsewhere" "$(readlink "$S4/.config")"
eq wl-conflict-silent "0" "$(grep -vc '^agyx: wrote' "$T/err")"
eq wl-missing-not-linked "absent" "$([ -e "$S4/.npm" ] || [ -L "$S4/.npm" ] || echo absent)"
mkdir "$RH/.cache"; launch s4 >/dev/null
eq wl-later-linked "link" "$(islink "$S4/.cache" "$RH/.cache")"
rmdir "$RH/.cache"; launch s4 >/dev/null
eq wl-dangling-removed "gone" "$([ -L "$S4/.cache" ] || [ -e "$S4/.cache" ] || echo gone)"
# doctor reports (section of profile s4 / s1)
sect() { ctl doctor | awk -v p="$1:" '/^profile /{on=($2==p)} on'; }
eq wl-doctor "1 1 1 1" "$(sect s4 | grep -c 'symlinks .gitconfig: linked') $(sect s4 | grep -c 'symlinks .ssh: CONFLICT') $(sect s4 | grep -c 'symlinks .npm: missing in the real home') $(sect s4 | grep -c 'symlinks .config: CONFLICT')"
# list file: comments, blanks, whitespace, invalid names
mkdir -p "$RH/.local" "$RH/mydir2"
mkdir -p "$(dirname "$HL")"; printf '# comment\n\n   # indented comment\n  .gitconfig  \n../etc\na/b\n.gemini\nLibrary\n.local\n.\n..\nmydir2\n' > "$HL"
S5=$DD/profiles/s5/home; mkdir -p "$S5"
launch s5 >/dev/null
eq wl-file-valid "link link" "$(islink "$S5/.gitconfig" "$RH/.gitconfig") $(islink "$S5/mydir2" "$RH/mydir2")"
eq wl-file-invalid-warned "7" "$(grep -c "symlinks: skipping invalid name" "$T/err")"
eq wl-file-not-linked ".local absent, .gemini is the shared link" "$([ -e "$S5/.local" ] || [ -L "$S5/.local" ] || printf '.local absent,') $(islink "$S5/.gemini" "$RH/.gemini" | sed 's/^link$/.gemini is the shared link/')"
eq wl-library-not-link "no" "$([ -L "$S5/Library" ] && echo yes || echo no)"
# profile default: show (or none) and set
rm -f "$DD/default"
eq default-none "none/0" "$(ctl profile default)/$(ctl profile default >/dev/null; echo $?)"
(ctl profile default other >/dev/null)
eq default-shown "other/other" "$(ctl profile default)/$(cat "$DD/default")"
eq default-launch-uses-it "other" "$(agyx 2>/dev/null | sed -n 's/^AGY_PROFILE=//p')"
eq default-use-gone "1" "$(ctl profile use other >/dev/null 2>&1 || echo 1)"
printf work > "$DD/default"
# doctor (any run) writes the default list once and never overwrites it
D2=$T/d2 RH3=$T/rh3
mkdir -p "$D2"
(AGYX_REAL_HOME=$RH3 AGYX_DATA_DIR=$D2 ctl doctor >/dev/null 2>&1)
L3=$RH3/.config/agyx/symlinks
eq doctor-writes-list ".gitconfig .ssh .config .npm .npmrc .bun .bunfig.toml .cache .cargo .rustup go Code GitHub " "$(grep -v '^#' "$L3" | tr '\n' ' ')"
eq doctor-not-in-data-dir "absent" "$([ -e "$D2/symlinks" ] || echo absent)"
echo mine > "$L3"; (AGYX_REAL_HOME=$RH3 AGYX_DATA_DIR=$D2 ctl doctor >/dev/null 2>&1)
eq doctor-keeps-list "mine" "$(cat "$L3")"
rm -rf "${DD:?}/profiles/s1" "${DD:?}/profiles/s2" "${DD:?}/profiles/s3" "${DD:?}/profiles/s4" "${DD:?}/profiles/s5"

# logged in via the profile keychain (item gemini/antigravity); the email comes from the profile's email file
mklk() { h=$DD/profiles/$1/home; mkdir -p "$h/Library/Keychains"; : > "$h/Library/Keychains/login.keychain-db"; echo "$h"; }
setemail() { printf '%s\n' "$2" > "$DD/profiles/$1/email"; }
h=$(mklk lk1); : > "$h/.fake-item"; setemail lk1 last@example.com
h=$(mklk lk2); : > "$h/.fake-item"
h=$(mklk lk3); : > "$h/.fake-item"; tokjson lk3 tok@example.com; setemail lk3 file@example.com
h=$(mklk lk4); : > "$h/.fake-item"; printf '{"token":{"access_token":"SECRET-ACCESS-lk4"},"auth_method":"oauth"}\n' > "$(tokdir lk4)"
h=$(mklk lk5); setemail lk5 nobody@example.com
h=$(mklk lk6); : > "$h/.fake-item"; setemail lk6 last@example.com
h=$(mklk lk7); : > "$h/.fake-item"; tokjson lk7 fromtok@example.com
: > "$SECLOG"
lst=$(ctl profile list)
row() { echo "$lst" | grep "^$1 " | sed 's/  */ /g'; }
eq lk-email-file "lk1 last@example.com" "$(row lk1)"
eq lk-keychain-no-email "lk2 logged in, email unknown" "$(row lk2)"
eq lk-email-file-wins-over-token "lk3 file@example.com" "$(row lk3)"
eq lk-token-without-field-unknown "lk4 logged in, email unknown" "$(row lk4)"
eq lk-no-item-no-token "lk5 not logged in" "$(row lk5)"
eq lk-token-field-fallback "lk7 fromtok@example.com" "$(row lk7)"
eq lk-dup-warning "1" "$(echo "$lst" | grep -c 'WARNING: profiles lk1 lk6 are logged in to the same Google account (last@example.com)')"
eq lk-doctor "1" "$(ctl doctor | grep -c '^profile lk1: last@example.com, home ')"
K=$DD/profiles/lk1/home/Library/Keychains/login.keychain-db
eq lk-find-call "HOME=$DD/profiles/lk1/home find-generic-password -s gemini -a antigravity $K" "$(grep 'HOME=[^ ]*/lk1/home find-generic' "$SECLOG" | head -n 1)"
eq lk-never-secret "0" "$(grep find-generic-password "$SECLOG" | grep -c -e ' -w' -e ' -g')"
eq lk-no-secrets-printed "0" "$( (echo "$lst"; ctl doctor) | grep -c SECRET)"
for n in lk1 lk2 lk3 lk4 lk5 lk6 lk7; do rm -rf "${DD:?}/profiles/$n"; done


# whitelist file location: ${XDG_CONFIG_HOME:-<real home>/.config}/agyx/symlinks
RH4=$T/rh4 XDG=$T/xdg
mkdir -p "$T/d3"
(AGYX_REAL_HOME=$RH4 XDG_CONFIG_HOME=$XDG AGYX_DATA_DIR=$T/d3 ctl doctor >/dev/null 2>&1)
eq xdg-abs-written "present/absent" "$([ -f "$XDG/agyx/symlinks" ] && echo present)/$([ -e "$RH4/.config/agyx/symlinks" ] || echo absent)"
mkdir -p "$T/cwd"
(cd "$T/cwd" && AGYX_REAL_HOME=$RH4 XDG_CONFIG_HOME=relative/dir AGYX_DATA_DIR=$T/d3 ctl doctor >/dev/null 2>&1)
eq xdg-relative-ignored "present/absent" "$([ -f "$RH4/.config/agyx/symlinks" ] && echo present)/$([ -e "$T/cwd/relative" ] || echo absent)"
(AGYX_REAL_HOME=$RH4 XDG_CONFIG_HOME=$XDG AGYX_DATA_DIR=$T/d3 ctl doctor | grep -c "^symlinks: $XDG/agyx/symlinks\$") > "$T/n"
eq doctor-links-path "1" "$(cat "$T/n")"
mkdir -p "$T/rh5"; echo x > "$T/rh5/.config"
eq doctor-links-path-missing "1" "$(AGYX_REAL_HOME=$T/rh5 ctl doctor | grep -c "^symlinks: $T/rh5/.config/agyx/symlinks (missing")"
# launch uses that file; the old <data>/symlinks is no longer read
mkdir -p "$RH/mydir2" "$RH/ignored-by-xdg" "$XDG/agyx"
echo mydir2 > "$XDG/agyx/symlinks"
echo ignored-by-xdg > "$DD/symlinks"
S7=$DD/profiles/s7/home; mkdir -p "$S7"
(XDG_CONFIG_HOME=$XDG launch s7 >/dev/null)
eq xdg-launch-uses-file "link/absent/absent" "$(islink "$S7/mydir2" "$RH/mydir2")/$([ -e "$S7/.gitconfig" ] || echo absent)/$([ -e "$S7/ignored-by-xdg" ] || echo absent)"
rm -rf "${DD:?}/profiles/s7"; rm -f "$DD/symlinks"


# ---- whole shared ~/.gemini: one link per profile, the token blocker, migration, email ----
# fl PROFILE: launch in the current fresh environment ($N), trash folder under $N/trash
fl() { fx env PATH="${FLPATH:-$SP}" AGYX_REAL_AGY="$T/fake-agy" AGYX_TRASH_DIR="$N/trash" FAKE_RUN=true "$AX" --profile "$1" </dev/null 2>"$T/err"; }
wfresh() { N=$T/$1; rm -rf "$N"; mkdir -p "$N/rh" "$N/data/profiles/p/home"; }
BL=.gemini/antigravity-cli/antigravity-oauth-token

# a fresh profile gets the single link; the layout is exactly the target layout
wfresh w1
out=$(fl p)
eq w-stdout-empty "" "$out"
eq w-link "link" "$(islink "$N/data/profiles/p/home/.gemini" "$N/rh/.gemini")"
eq w-link-target "$N/rh/.gemini" "$(readlink "$N/data/profiles/p/home/.gemini")"
eq w-profile-layout "cli.log home log" "$(ls -A "$N/data/profiles/p" | tr '\n' ' ' | sed 's/ $//')"
eq w-home-layout ".config .fake-default .gemini Library" "$(ls -A "$N/data/profiles/p/home" | tr '\n' ' ' | sed 's/ $//')"
eq w-no-drift "absent" "$(find "$N/data" -name 'agyx-drift*' | grep -c . | sed 's/^0$/absent/')"
eq w-blocker-dir "dir/README" "$([ -d "$N/rh/$BL" ] && [ ! -L "$N/rh/$BL" ] && echo dir)/$(ls "$N/rh/$BL")"
eq w-blocker-readme "1" "$(grep -c 'cannot write a token file' "$N/rh/$BL/README")"
# steady state: nothing changes, nothing printed, and no helper process is started by the sync code
before=$(snap "$N/data/profiles" "$N/rh/.gemini")
STUBS=$T/stubs; STUBLOG=$T/stublog; rm -rf "$STUBS"; mkdir "$STUBS"; : > "$STUBLOG"
for n in ln rm mv find date cmp mkdir ls cat sed tr head; do
  printf '#!/bin/sh\necho %s >> "%s"\nexec %s "$@"\n' "$n" "$STUBLOG" "$(command -v "$n")" > "$STUBS/$n"
  chmod +x "$STUBS/$n"
done
AGYX_LOG_STAMP=20260101_000000; export AGYX_LOG_STAMP # no date fork to name the log
out=$(FLPATH="$STUBS:$SP" fl p)
unset AGYX_LOG_STAMP
after=$(snap "$N/data/profiles" "$N/rh/.gemini")
eq w-steady-same "$before/0/" "$after/$(grep -c . "$T/err")/$out"
eq w-steady-fork-free "ln" "$(cat "$STUBLOG")" # the one process is the cli.log link of the new log file
# a link pointing elsewhere is replaced; a missing one is created
rm "$N/data/profiles/p/home/.gemini"; ln -s /elsewhere "$N/data/profiles/p/home/.gemini"; fl p >/dev/null
eq w-link-elsewhere "link" "$(islink "$N/data/profiles/p/home/.gemini" "$N/rh/.gemini")"
rm "$N/data/profiles/p/home/.gemini"; fl p >/dev/null
eq w-link-missing "link" "$(islink "$N/data/profiles/p/home/.gemini" "$N/rh/.gemini")"

# the blocker: created when missing (doctor says so first), reported by doctor
rm -rf "$N/rh/$BL"
eq w-doctor-blocker-missing "1" "$(fx env PATH="$SP" "$AX" doctor </dev/null 2>/dev/null | grep -c '^token blocker: missing (created on next launch)')"
fl p >/dev/null
eq w-blocker-recreated "dir" "$([ -d "$N/rh/$BL" ] && echo dir)"
eq w-doctor-blocker-ok "1" "$(fx env PATH="$SP" "$AX" doctor </dev/null 2>/dev/null | grep -c '^token blocker: ok')"
eq w-doctor-gemini-line "1" "$(fx env PATH="$SP" "$AX" doctor </dev/null 2>/dev/null | grep -c '^  .gemini: linked to the shared ~/.gemini')"
# a regular file at the blocker path stops every launch and nothing changes (the file is never touched)
rm -rf "$N/rh/$BL"; printf 'SECRET-TOKEN-CONTENT\n' > "$N/rh/$BL"
mkdir -p "$N/data/profiles/q/home"
before=$(snap "$N/data/profiles" "$N/rh/.gemini"); : > "$LAUNCHLOG"
for pr in p q; do
  out=$(fl $pr); rc=$?
  eq "w-blocking-$pr" "nonzero,empty,msg" "$([ $rc -ne 0 ] && echo nonzero),$([ -z "$out" ] && echo empty),$(grep -q 'not starting this profile: ~/.gemini/antigravity-cli/antigravity-oauth-token exists and is not a directory' "$T/err" && grep -q 'every account could read that file' "$T/err" && grep -q 'agyx never reads, moves or deletes it' "$T/err" && grep -q 'plain agy will ask you to sign in again' "$T/err" && echo msg)"
done
after=$(snap "$N/data/profiles" "$N/rh/.gemini")
eq w-blocking-nothing-changed "$before/0/SECRET-TOKEN-CONTENT" "$after/$(wc -c < "$LAUNCHLOG" | tr -d ' ')/$(cat "$N/rh/$BL")"
eq w-blocking-not-printed "0" "$(grep -c SECRET "$T/err")"
eq w-doctor-blocker-blocking "1" "$(fx env PATH="$SP" "$AX" doctor </dev/null 2>/dev/null | grep -c '^token blocker: BLOCKING')"
rm -f "$N/rh/$BL"

# ---- migration of profiles in the per-entry layout ----
wmk() { mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" > "$1"; }
wfresh m1; rmdir "$N/data/profiles/p/home" "$N/data/profiles/p"
GS=$N/rh/.gemini
mkdir -p "$GS/antigravity-cli/log" "$GS/skills" "$GS/conversations" "$GS/antigravity-cli/mcp"
wmk "$GS/settings.json" shared-settings; wmk "$GS/antigravity-cli/mcp.json" mcp; wmk "$GS/antigravity-cli/log/shared.log" sharedlog
wmk "$GS/conversations/a.pb" a; wmk "$GS/same.txt" same
wmk "$GS/c-new.txt" shared-old-c; touch -t 202001010000 "$GS/c-new.txt"
wmk "$GS/c-old.txt" shared-new-c; touch -t 202401010000 "$GS/c-old.txt"
mkdir -p "$GS/fd"; wmk "$GS/fd/inner" in-shared-dir
wmk "$GS/antigravity-cli/mcp/tool.json" shared-tool
mkold() { # profile: the per-entry layout of 0.1.0-0.1.2
  h=$N/data/profiles/$1/home; g=$h/.gemini; a=$g/antigravity-cli
  mkdir -p "$a/log" "$g/brain" "$g/conversations" "$a/mcp"
  ln -s "$GS/settings.json" "$g/settings.json"; ln -s "$GS/skills" "$g/skills"; ln -s "$GS/antigravity-cli/mcp.json" "$a/mcp.json"
  wmk "$a/log/x.log" "10:00 applyAuthResult ok email=fromlog-$1@example.com"
  wmk "$a/cli.log" clilog; wmk "$a/jetbox_summaries_proto.pb" jb; wmk "$a/conv.db-wal" wal
  wmk "$g/brain/b1" brain-one; wmk "$g/conversations/b.pb" b; wmk "$g/same.txt" same
  wmk "$g/c-new.txt" profile-new-c; touch -t 202401010000 "$g/c-new.txt"
  wmk "$g/c-old.txt" profile-old-c; touch -t 202001010000 "$g/c-old.txt"
  wmk "$g/fd" file-in-profile
  wmk "$a/mcp/tool.json" shared-tool; wmk "$a/mcp/own.json" own-tool
}
mkold old; mkold old2; mkold old3
# old: token file + keychain item; old2: token file, no keychain item; old3: no token file, log email only
printf '{"token":{"access_token":"SECRET-ACCESS","refresh_token":"SECRET-REFRESH"},"auth_method":"oauth","id_token_email":"fromtoken@example.com"}\n' > "$N/data/profiles/old/home/$BL"
printf '{"token":{"access_token":"SECRET-ACCESS2"},"auth_method":"oauth"}\n' > "$N/data/profiles/old2/home/$BL"
mkdir -p "$N/data/profiles/old/home" && : > "$N/data/profiles/old/home/.fake-item"
: > "$N/data/profiles/old3/home/.fake-item"
out=$(fl old); rc=$?
OH=$N/data/profiles/old/home
eq m-rc-stdout "0/" "$rc/$out"
eq m-link "link" "$(islink "$OH/.gemini" "$GS")"
eq m-layout "cli.log email home log" "$(ls -A "$N/data/profiles/old" | tr '\n' ' ' | sed 's/ $//')"
eq m-home-layout ".config .fake-default .fake-item .gemini Library" "$(ls -A "$OH" | tr '\n' ' ' | sed 's/ $//')"
eq m-email-from-token "fromtoken@example.com" "$(cat "$N/data/profiles/old/email")"
eq m-disjoint-moved "brain-one/b" "$(cat "$GS/brain/b1")/$(cat "$GS/conversations/b.pb")"
eq m-shared-kept "shared-settings/a/mcp" "$(cat "$GS/settings.json")/$(cat "$GS/conversations/a.pb")/$(cat "$GS/antigravity-cli/mcp.json")"
eq m-nested-merge "own-tool/shared-tool" "$(cat "$GS/antigravity-cli/mcp/own.json")/$(cat "$GS/antigravity-cli/mcp/tool.json")"
eq m-identical "same" "$(cat "$GS/same.txt")"
eq m-profile-newer-wins "profile-new-c" "$(cat "$GS/c-new.txt")"
eq m-shared-newer-wins "shared-new-c" "$(cat "$GS/c-old.txt")"
eq m-file-vs-dir "in-shared-dir" "$(cat "$GS/fd/inner")"
eq m-no-links-left "2" "$(find "$N/data/profiles/old" -type l ! -name cli.log | grep -c .)"
TR=$(echo "$N"/trash/agyx-old-*)
eq m-trash-one-folder "1" "$(echo "$N"/trash/agyx-old-* | wc -w | tr -d ' ')"
eq m-trash-logs "clilog/jb/wal/10:00 applyAuthResult ok email=fromlog-old@example.com" "$(cat "$TR/antigravity-cli/cli.log")/$(cat "$TR/antigravity-cli/jetbox_summaries_proto.pb")/$(cat "$TR/antigravity-cli/conv.db-wal")/$(cat "$TR/antigravity-cli/log/x.log")"
eq m-trash-token "1" "$(grep -c SECRET-ACCESS "$TR/antigravity-cli/antigravity-oauth-token" | sed 's/^[1-9].*/1/')"
eq m-trash-losers "profile-old-c/shared-old-c/file-in-profile" "$(cat "$TR/c-old.txt")/$(cat "$TR/c-new.txt")/$(cat "$TR/fd")"
eq m-shared-log-untouched "sharedlog" "$(cat "$GS/antigravity-cli/log/shared.log")"
eq m-only-private-files ".fake-default .fake-item email " "$(find "$N/data/profiles/old" -path '*/Library' -prune -o -path '*/log' -prune -o -type f -print | sed 's|.*/||' | sort | tr '\n' ' ')"
eq m-summary-line "1" "$(grep -c "^agyx: profile old: its .gemini was merged into the shared ~/.gemini: .* entries moved, 3 old links removed, .* items to the Trash (.*/trash/agyx-old-[0-9]*)\$" "$T/err")"
eq m-token-msg-keychain "1" "$(grep -c "^agyx: profile old: its login token file was moved to the Trash (.*). Its keychain holds a login, so nothing else is needed.\$" "$T/err")"
eq m-no-secrets-printed "0" "$(grep -c SECRET "$T/err")"
before=$(snap "$N/data/profiles/old" "$GS" "$N/trash"); out=$(fl old); after=$(snap "$N/data/profiles/old" "$GS" "$N/trash")
eq m-second-launch "$before/0/" "$after/$(grep -c . "$T/err")/$out"
# without a keychain item the message says to log in again; the log email is kept when there is no token
fl old2 >/dev/null
eq m-token-msg-no-keychain "1" "$(grep -c "^agyx: profile old2: its login token file was moved to the Trash (.*), and its keychain holds no login: run 'agyx profile login old2' again if agy asks you to sign in.\$" "$T/err")"
eq m-email-old2 "fromlog-old2@example.com" "$(cat "$N/data/profiles/old2/email")"
fl old3 >/dev/null
eq m-email-from-log "fromlog-old3@example.com" "$(cat "$N/data/profiles/old3/email")"
eq m-no-token-msg "0" "$(grep -c 'login token file' "$T/err")"
fx env PATH="$SP" "$AX" profile list </dev/null 2>/dev/null > "$T/list.out"
eq m-list-emails "old fromtoken@example.com;old2 not logged in;old3 fromlog-old3@example.com" "$(sed 's/  */ /g; s/ (default)//' "$T/list.out" | tr '\n' ';' | sed 's/;$//')"
eq m-list-no-secret "0" "$(grep -c SECRET "$T/list.out")"
# migration is not repeated and a shared token blocker is not needed to exist beforehand
eq m-blocker-intact "dir" "$([ -d "$N/rh/$BL" ] && echo dir)"

# ---- email after a successful login (from the shared logs written during the login) ----
wfresh e1; rmdir "$N/data/profiles/p/home" "$N/data/profiles/p"
wmk "$N/rh/.gemini/antigravity-cli/log/stale.log" "09:00 applyAuthResult ok email=stale@example.com"; touch -t 202001010000 "$N/rh/.gemini/antigravity-cli/log/stale.log"
LOGIN='touch $HOME/.fake-item; sleep 1; mkdir -p $HOME/.gemini/antigravity-cli/log; echo "11:00 applyAuthResult ok email=first@example.com" > $HOME/.gemini/antigravity-cli/log/new.log; echo "11:01 applyAuthResult ok email=last@example.com" >> $HOME/.gemini/antigravity-cli/log/new.log'
out=$(fx env PATH="$SP" AGYX_REAL_AGY="$T/fake-agy" FAKE_RUN="$LOGIN" "$AX" profile login acct1 2>/dev/null </dev/null)
eq email-after-login "last@example.com" "$(cat "$N/data/profiles/acct1/email")"
eq email-layout "cli.log email home log" "$(ls -A "$N/data/profiles/acct1" | tr '\n' ' ' | sed 's/ $//')"
eq email-in-list "acct1 last@example.com (default)" "$(fx env PATH="$SP" "$AX" profile list </dev/null 2>/dev/null | sed 's/  */ /g')"
# a login that wrote no new log line leaves no email file (the stale shared log is ignored)
out=$(fx env PATH="$SP" AGYX_REAL_AGY="$T/fake-agy" FAKE_RUN='touch $HOME/.fake-item' "$AX" profile login acct2 2>/dev/null </dev/null)
eq email-ignores-old-logs "absent" "$([ -e "$N/data/profiles/acct2/email" ] && echo present || echo absent)"
eq email-unknown-listed "acct2 logged in, email unknown" "$(fx env PATH="$SP" "$AX" profile list </dev/null 2>/dev/null | sed 's/  */ /g' | grep '^acct2')"
# a failed login writes nothing
fx env PATH="$SP" AGYX_REAL_AGY="$T/fake-agy" FAKE_RUN='echo "11:00 applyAuthResult ok email=nope@example.com" > $HOME/.gemini/antigravity-cli/log/z.log' "$AX" profile login acct3 >/dev/null 2>&1 </dev/null
eq email-failed-login "absent" "$([ -e "$N/data/profiles/acct3/email" ] && echo present || echo absent)"
eq email-no-marker-left "0" "$(find "$N/data/profiles" -name '.login-start' | grep -c .)"
# duplicate warning uses the email files
printf 'last@example.com\n' > "$N/data/profiles/acct2/email"
eq email-dup-warning "1" "$(fx env PATH="$SP" "$AX" profile list </dev/null 2>/dev/null | grep -c 'WARNING: profiles acct1 acct2 are logged in to the same Google account (last@example.com)')"


# ---- login writes its own agy log (--log-file) and reads the email from that file only ----
wfresh o1; rmdir "$N/data/profiles/p/home" "$N/data/profiles/p"
# another instance logs a different account into the shared log while this login runs; it is ignored
OWN='touch $HOME/.fake-item; sleep 1; mkdir -p $HOME/.gemini/antigravity-cli/log; echo "11:00 applyAuthResult ok email=other@example.com" > $HOME/.gemini/antigravity-cli/log/shared-new.log; echo "11:01 applyAuthResult ok email=mine@example.com" > "$FAKE_LOGFILE"; printf "%s\n" "$FAKE_LOGFILE" > "$N_LOGPATH"'
out=$(fx env PATH="$SP" N_LOGPATH="$T/logpath" AGYX_REAL_AGY="$T/fake-agy" FAKE_RUN="$OWN" "$AX" profile login own1 2>/dev/null </dev/null)
eq login-own-log-email "mine@example.com" "$(cat "$N/data/profiles/own1/email")"
lp=$(cat "$T/logpath")
eq login-own-log-path "$N/data/profiles/own1/log" "$(dirname "$lp")"
eq login-own-log-name "yes" "$(basename "$lp" | grep -Eq '^cli-[0-9]{8}_[0-9]{6}\.log$' && echo yes)"
eq login-own-log-deleted "0" "$(find "$N/data/profiles" -name '.login-*' | grep -c .)"
# the file exists but has no email: unknown, not the shared log
out=$(fx env PATH="$SP" AGYX_REAL_AGY="$T/fake-agy" FAKE_RUN='touch $HOME/.fake-item; sleep 1; echo "11:00 applyAuthResult ok email=other2@example.com" > $HOME/.gemini/antigravity-cli/log/shared-new2.log; echo "12:00 nothing here" > "$FAKE_LOGFILE"' "$AX" profile login own2 2>/dev/null </dev/null)
eq login-own-log-no-email "absent" "$([ -e "$N/data/profiles/own2/email" ] && echo present || echo absent)"
# the file is never created (flag ignored): the shared logs written during the login are used
out=$(fx env PATH="$SP" AGYX_REAL_AGY="$T/fake-agy" FAKE_RUN='touch $HOME/.fake-item; sleep 1; echo "13:00 applyAuthResult ok email=fallback@example.com" > $HOME/.gemini/antigravity-cli/log/shared-new3.log' "$AX" profile login own3 2>/dev/null </dev/null)
eq login-flag-ignored-fallback "fallback@example.com" "$(cat "$N/data/profiles/own3/email")"
eq login-no-leftovers "0" "$(find "$N/data/profiles" -name '.login-*' | grep -c .)"

# ---- a token file at the blocker path: ask in a terminal, refuse otherwise ----
printf 'y\n' > "$T/ans-y2"; printf 'n\n' > "$T/ans-n2"; printf '\n' > "$T/ans-enter2"; : > "$T/ans-eof2"
tokwant="agyx: found a login token file at ~/.gemini/antigravity-cli/antigravity-oauth-token${nl}  It is probably plain agy's login. While it exists, every agyx profile could read it.${nl}  Move it to the Trash? Plain agy will ask you to sign in again. [y/N] "
flt() { fx env PATH="$SP" AGYX_REAL_AGY="$T/fake-agy" AGYX_TRASH_DIR="$N/trash" FAKE_RUN=true AGYX_TTY="$T/ans-$1" "$AX" --profile p </dev/null 2>"$T/err"; }
tk() { wfresh "$1"; mkdir -p "$N/rh/.gemini/antigravity-cli"; printf 'SECRET-TOKEN-CONTENT\n' > "$N/rh/$BL"; }
tk t1; : > "$LAUNCHLOG"
out=$(flt y2); rc=$?
eq tokfile-yes "0,empty,prompt,moved,blocker,kept,launched" "$rc,$([ -z "$out" ] && echo empty),$([ "$(grep -v '^agyx: wrote' "$T/err" | sed -n '1,3p' | sed 's/\[y\/N\] .*/[y\/N] /')" = "$tokwant" ] && echo prompt),$(grep -c 'agyx: moved the token file to .*/trash/agyx-token-' "$T/err" | sed 's/0/-/;s/1/moved/'),$([ -d "$N/rh/$BL" ] && [ -f "$N/rh/$BL/README" ] && echo blocker),$(cat "$N"/trash/agyx-token-*/antigravity-oauth-token | tr -d '\n' | sed 's/SECRET-TOKEN-CONTENT/kept/'),$([ -s "$LAUNCHLOG" ] && echo launched)"
eq tokfile-yes-no-secret-printed "0" "$(grep -c SECRET "$T/err")"
for a in n2 enter2 eof2; do
  tk t2; : > "$LAUNCHLOG"
  out=$(flt $a); rc=$?
  eq "tokfile-no-$a" "nonzero,empty,refusal,intact,0" "$([ $rc -ne 0 ] && echo nonzero),$([ -z "$out" ] && echo empty),$(grep -q 'not starting this profile' "$T/err" && echo refusal),$(cat "$N/rh/$BL" | sed 's/SECRET-TOKEN-CONTENT/intact/'),$(wc -c < "$LAUNCHLOG" | tr -d ' ')"
done
# without a terminal there is no question at all (also with AGYX_ASSUME_YES)
tk t3
out=$(fx env PATH="$SP" AGYX_REAL_AGY="$T/fake-agy" AGYX_ASSUME_YES=1 FAKE_RUN=true "$AX" --profile p </dev/null 2>"$T/err"); rc=$?
eq tokfile-noterm "nonzero,refusal,no-question,intact" "$([ $rc -ne 0 ] && echo nonzero),$(grep -q 'not starting this profile' "$T/err" && echo refusal),$(grep -q 'Move it to the Trash' "$T/err" || echo no-question),$(sed 's/SECRET-TOKEN-CONTENT/intact/' "$N/rh/$BL")"

# ---- agyx uninstall ----
UP=$T/ubin; rm -rf "$UP"; mkdir "$UP"
printf '#!/bin/sh\necho "brew $*" >> "%s"\n' "$T/brewlog" > "$UP/brew"; chmod +x "$UP/brew"
ln -s "$T/fake-security" "$UP/security"
# ufresh NAME: default-layout install (data in ~/.local/share/agyx) with profiles a b c, config, blocker, shared .gemini
ufresh() {
  N=$T/$1; rm -rf "$N"; mkdir -p "$N/rh/.local/share/agyx/bin" "$N/rh/.local/bin" "$N/rh/.config/agyx" "$N/rh/.gemini/antigravity-cli/antigravity-oauth-token"
  UD=$N/rh/.local/share/agyx
  for pr in a b c; do mkdir -p "$UD/profiles/$pr/home/Library/Keychains"; : > "$UD/profiles/$pr/home/Library/Keychains/login.keychain-db"; done
  ln -s "$T/fake-agy" "$UD/real-agy"; echo a > "$UD/default"; printf '.gitconfig\n' > "$N/rh/.config/agyx/symlinks"
  printf 'agyx README\n' > "$N/rh/.gemini/antigravity-cli/antigravity-oauth-token/README"; echo keep > "$N/rh/.gemini/settings.json"
  : > "$SECLOG"; : > "$T/brewlog"
}
ux() { env -u AGYX_DATA_DIR AGYX_REAL_HOME="$N/rh" AGYX_TRASH_DIR="$N/trash" PATH="$UP:$SP" "$@"; }
printf 'y\n' > "$T/ua-y"; printf 'n\n' > "$T/ua-n"; printf '\n' > "$T/ua-enter"
# a checkout install: the PATH link in ~/.local/bin goes, the checkout stays
ufresh u1; ln -s "$here/bin/agyx" "$N/rh/.local/bin/agyx"
out=$(ux env AGYX_TTY="$T/ua-y" "$here/bin/agyx" uninstall 2>"$T/err" </dev/null); rc=$?
uwant="agyx uninstall will remove:${nl}  ~/.local/share/agyx/   profiles a, b, c (their keychains and logins are deleted)${nl}  ~/.config/agyx/   your symlinks list${nl}  ~/.gemini/antigravity-cli/antigravity-oauth-token/   the token-file blocker${nl}  agyx itself   (the link ~/.local/bin/agyx)${nl}Kept: ~/.gemini (shared settings, history and conversations) and plain agy.${nl}Apps set up with ~/.local/share/agyx/bin/agy (for example T3 Code) will stop working.${nl}Remove? [y/N] "
eq uninstall-text "$uwant" "$(sed '/^$/d' "$T/err" | sed -n '1,8p' | sed 's/\(Remove? \[y\/N\] \).*/\1/' | head -c 2000)"
eq uninstall-checkout "0,gone,gone,gone,kept,kept,kept" "$rc,$([ ! -e "$N/rh/.local/share/agyx" ] && echo gone),$([ ! -e "$N/rh/.config/agyx" ] && echo gone),$([ ! -e "$N/rh/.gemini/antigravity-cli/antigravity-oauth-token" ] && echo gone),$(cat "$N/rh/.gemini/settings.json" | sed 's/keep/kept/'),$([ -d "$N/rh/.gemini/antigravity-cli" ] && echo kept),$([ -x "$here/bin/agyx" ] && [ ! -L "$N/rh/.local/bin/agyx" ] && echo kept)"
UTR=$(echo "$N"/trash/agyx-uninstall-*)
eq uninstall-trash "3/1/1" "$(find "$UTR/data/profiles" -mindepth 1 -maxdepth 1 | grep -c .)/$([ -f "$UTR/config/symlinks" ] && echo 1)/$(echo "$N"/trash/agyx-uninstall-* | wc -w | tr -d ' ')"
eq uninstall-keychains "3" "$(grep -c "delete-keychain" "$SECLOG")"
eq uninstall-keychain-call "HOME=$N/rh/.local/share/agyx/profiles/a/home delete-keychain $N/rh/.local/share/agyx/profiles/a/home/Library/Keychains/login.keychain-db" "$(grep 'delete-keychain' "$SECLOG" | head -n 1)"
eq uninstall-keychains-before-move "3" "$(grep -c 'delete-keychain' "$SECLOG")"
eq uninstall-no-brew "" "$(cat "$T/brewlog")"
# the blocker stays when it holds anything besides agyx's README; answering No removes nothing
ufresh u2; echo extra > "$N/rh/.gemini/antigravity-cli/antigravity-oauth-token/other"
out=$(ux env AGYX_TTY="$T/ua-y" "$here/bin/agyx" uninstall 2>"$T/err" </dev/null)
eq uninstall-blocker-kept "kept/gone" "$([ -f "$N/rh/.gemini/antigravity-cli/antigravity-oauth-token/other" ] && echo kept)/$([ ! -e "$N/rh/.local/share/agyx" ] && echo gone)"
eq uninstall-blocker-line-absent "0" "$(grep -c 'the token-file blocker' "$T/err")"
for a in n enter; do
  ufresh u3
  out=$(ux env AGYX_TTY="$T/ua-$a" "$here/bin/agyx" uninstall 2>"$T/err" </dev/null); rc=$?
  eq "uninstall-no-$a" "nonzero,present,present,0,nothing" "$([ $rc -ne 0 ] && echo nonzero),$([ -d "$N/rh/.local/share/agyx" ] && echo present),$([ -d "$N/rh/.config/agyx" ] && echo present),$(grep -c delete-keychain "$SECLOG"),$(grep -q 'nothing was removed' "$T/err" && echo nothing)"
done
: > "$T/ua-eof"
ufresh u3; ux env AGYX_TTY="$T/ua-eof" "$here/bin/agyx" uninstall >/dev/null 2>&1 </dev/null
eq uninstall-eof "present" "$([ -d "$N/rh/.local/share/agyx" ] && echo present)"
# no terminal: refuse, unless AGYX_ASSUME_YES=1
ufresh u4
out=$(ux "$here/bin/agyx" uninstall 2>"$T/err" </dev/null); rc=$?
eq uninstall-noterm "nonzero,empty,msg,present" "$([ $rc -ne 0 ] && echo nonzero),$([ -z "$out" ] && echo empty),$(grep -q 'uninstall needs a terminal to ask (or set AGYX_ASSUME_YES=1); nothing was removed.' "$T/err" && echo msg),$([ -d "$N/rh/.local/share/agyx" ] && echo present)"
ux env AGYX_ASSUME_YES=1 "$here/bin/agyx" uninstall >/dev/null 2>&1 </dev/null
eq uninstall-assume-yes "gone" "$([ ! -e "$N/rh/.local/share/agyx" ] && echo gone)"
# a running agy (matched on the command line) blocks it, with its PID
ufresh u5
printf '#!/bin/sh\nsleep 20\n:\n' > "$T/agy-sleeper"; chmod +x "$T/agy-sleeper"
ln -sfn "$T/agy-sleeper" "$N/rh/.local/share/agyx/real-agy"
"$N/rh/.local/share/agyx/real-agy" & spid=$!
sleep 1
out=$(ux env AGYX_TTY="$T/ua-y" "$here/bin/agyx" uninstall 2>"$T/err" </dev/null); rc=$?
eq uninstall-running "nonzero,pid,present,no-question" "$([ $rc -ne 0 ] && echo nonzero),$(grep -c "agy is still running (PIDs: .*$spid" "$T/err" | sed 's/1/pid/'),$([ -d "$N/rh/.local/share/agyx" ] && echo present),$(grep -q 'Remove?' "$T/err" || echo no-question)"
kill "$spid" 2>/dev/null; wait "$spid" 2>/dev/null
# the Homebrew install: the program is removed with brew uninstall at the end
ufresh u6; TP2=$(cd "$T" && pwd -P); HB2=$TP2/hb2; brewlayout "$HB2" 0.1.2
out=$(ux env AGYX_TTY="$T/ua-y" "$HB2/bin/agyx" uninstall 2>"$T/err" </dev/null); rc=$?
eq uninstall-brew "0,brew uninstall agyx,gone,line,untap" "$rc,$(cat "$T/brewlog"),$([ ! -e "$N/rh/.local/share/agyx" ] && echo gone),$(grep -c '  agyx itself   (brew uninstall agyx)' "$T/err" | sed 's/1/line/'),$(echo "$out" | grep -q 'brew untap iamdin/tap' && echo untap)"
# any other location: it says what to delete and removes nothing of the program
ufresh u7; mkdir -p "$T/otherinst"; cp -R "$here/bin" "$here/runtime" "$T/otherinst/"
out=$(ux env AGYX_TTY="$T/ua-y" "$T/otherinst/bin/agyx" uninstall 2>"$T/err" </dev/null); rc=$?
eq uninstall-other "0,line,msg,still-there" "$rc,$(grep -c "agyx itself   (delete $(cd "$T/otherinst/bin" && pwd -P)/agyx yourself)" "$T/err" | sed 's/1/line/'),$(echo "$out" | grep -q 'to finish, delete .* yourself' && echo msg),$([ -x "$T/otherinst/bin/agyx" ] && echo still-there)"
# nothing installed yet: the list only has the program line; nothing is created
N=$T/u8; rm -rf "$N"; mkdir -p "$N/rh"
out=$(ux env AGYX_ASSUME_YES=1 "$T/otherinst/bin/agyx" uninstall 2>"$T/err" </dev/null); rc=$?
eq uninstall-empty "0,nothing-created" "$rc,$([ ! -e "$N/rh/.local" ] && [ ! -e "$N/rh/.config" ] && [ ! -e "$N/rh/.gemini" ] && echo nothing-created)"

# ---- per-profile logs, laid out like agy's own: <profile>/log/ and <profile>/cli.log -> log/<newest> ----
LD() { echo "$N/data/profiles/${1:-p}/log"; }
PD() { echo "$N/data/profiles/${1:-p}"; }
ll() { fx env PATH="$SP" AGYX_REAL_AGY="$T/fake-agy" "$AX" --profile p "$@" </dev/null 2>"$T/err"; }
llq() { FAKE_RUN=true ll "$@"; }
wfresh l1
# the flag comes first, then the user's arguments untouched
AGYX_LOG_STAMP=20260101_120000; export AGYX_LOG_STAMP
out=$(ll -c)
eq log-flag-first "LOGFIRST=$(LD)/cli-20260101_120000.log" "$(echo "$out" | grep '^LOGFIRST=')"
eq log-flag-args-untouched "ARG=-c" "$(echo "$out" | grep '^ARG=')"
eq log-file-created-empty "0" "$(wc -c < "$(LD)/cli-20260101_120000.log" | tr -d ' ')"
eq log-cli-symlink "log/cli-20260101_120000.log" "$(readlink "$(PD)/cli.log")"
eq log-cli-symlink-resolves "yes" "$([ -f "$(PD)/cli.log" ] && echo yes)"
out=$(ll models); eq log-flag-before-subcommand "ARG=models" "$(echo "$out" | grep '^ARG=')"
out=$(ll -p hello); eq log-flag-print-mode "ARG=-p ARG=hello" "$(echo "$out" | grep '^ARG=' | tr '\n' ' ' | sed 's/ $//')"
# no two launches share a file, even in the same second
LC_ALL=C ls "$(LD)" > "$T/names"
eq log-unique-same-second "cli-20260101_120000.log cli-20260101_120000_02.log cli-20260101_120000_03.log" "$(tr '\n' ' ' < "$T/names" | sed 's/ $//')"
eq log-cli-symlink-newest "log/cli-20260101_120000_03.log" "$(readlink "$(PD)/cli.log")"
# acp writes acp-server-<stamp>-<pid>.log (the shim execs agy, so the pid is agy's) and leaves cli.log alone
out=$(ll acp)
al=$(echo "$out" | sed -n 's/^LOGFIRST=//p')
eq log-acp-name "yes" "$(basename "$al" | grep -Eq '^acp-server-20260101_120000-[0-9]+\.log$' && echo yes)"
eq log-acp-keeps-cli-link "log/cli-20260101_120000_03.log" "$(readlink "$(PD)/cli.log")"
eq log-acp-arg "ARG=acp" "$(echo "$out" | grep '^ARG=')"
# subcommands that never write a log get no file and no flag; a log file chosen by the caller is kept
before=$(ls "$(LD)" | wc -l | tr -d ' ')
res=
for a in help changelog "mcp list" "update --help" --help --version; do
  # shellcheck disable=SC2086 # $a is a word list on purpose
  out=$(ll $a); [ -z "$(echo "$out" | grep '^LOGFIRST=')" ] || res="$res $a"
done
eq log-flag-not-passed "" "$res"
out=$(ll models --log-file /x/own.log)
eq log-own-flag-respected "no-first/ARG=models ARG=--log-file ARG=/x/own.log" "$([ -z "$(echo "$out" | grep '^LOGFIRST=')" ] && echo no-first)/$(echo "$out" | grep '^ARG=' | tr '\n' ' ' | sed 's/ $//')"
eq log-no-file-for-those "$before" "$(ls "$(LD)" | wc -l | tr -d ' ')"
unset AGYX_LOG_STAMP
# the name is the launch time, like agy's own files; private modes
rm -rf "$(LD)" "$(PD)/cli.log"; llq >/dev/null
eq log-name-format "yes" "$(basename "$(echo "$(LD)"/cli-*.log)" | grep -Eq '^cli-[0-9]{8}_[0-9]{6}\.log$' && echo yes)"
eq log-private-mode "drwx------/-rw-------" "$(ls -ld "$(LD)" | cut -c1-10)/$(ls -l "$(LD)"/cli-*.log | cut -c1-10)"
out=$(llq true); eq log-stdout-empty "" "$out"
# nothing goes to the shared ~/.gemini log dir or cli.log
eq log-shared-untouched "absent/absent" "$([ -e "$N/rh/.gemini/antigravity-cli/log" ] && echo present || echo absent)/$([ -e "$N/rh/.gemini/antigravity-cli/cli.log" ] && echo present || echo absent)"
# retention mirrors agy: files whose mtime is more than 7 days old are deleted at launch, nothing else
NOWS=$(date +%Y%m%d_%H%M%S)
agedlog() { # name hours-old: a log file with that name and mtime
  : > "$(LD)/$1"; touch -t "$(date -v-"$2"H +%Y%m%d%H%M.%S)" "$(LD)/$1"
}
rm -rf "$(LD)"; mkdir -p "$(LD)"
n160=cli-$(date -v-160H +%Y%m%d_%H%M%S).log n170=cli-$(date -v-170H +%Y%m%d_%H%M%S).log
agedlog "$n160" 160; agedlog "$n170" 170
agedlog "acp-server-$(date -v-400H +%Y%m%d_%H%M%S)-77.log" 400
agedlog "cli-$(date -v-400H +%Y%m%d_%H%M%S)_02.log" 20     # old name, recent mtime: kept (mtime decides)
echo keep > "$(LD)/notes.txt"; touch -t 200001010000 "$(LD)/notes.txt"
AGYX_LOG_STAMP=$NOWS; export AGYX_LOG_STAMP
llq >/dev/null; unset AGYX_LOG_STAMP
eq log-prune-7-days "kept/gone/gone/kept/kept/kept" "$([ -e "$(LD)/$n160" ] && echo kept)/$([ ! -e "$(LD)/$n170" ] && echo gone)/$(ls "$(LD)"/acp-server-*-77.log >/dev/null 2>&1 && echo present || echo gone)/$(ls "$(LD)"/cli-*_02.log >/dev/null 2>&1 && echo kept)/$([ -e "$(LD)/notes.txt" ] && echo kept)/$([ -e "$(LD)/cli-$NOWS.log" ] && echo kept)"
# pruning starts no process unless a file may be old enough; then exactly one find
rm -rf "$T/pstubs"; mkdir "$T/pstubs"; : > "$STUBLOG"
for x in find rm ls head tail; do printf '#!/bin/sh\necho %s >> "%s"\nexec %s "$@"\n' "$x" "$STUBLOG" "$(command -v "$x")" > "$T/pstubs/$x"; chmod +x "$T/pstubs/$x"; done
rm -rf "$(LD)"; mkdir -p "$(LD)"; agedlog "cli-$(date -v-100H +%Y%m%d_%H%M%S).log" 100
fx env PATH="$T/pstubs:$SP" AGYX_REAL_AGY="$T/fake-agy" FAKE_RUN=true "$AX" --profile p </dev/null 2>/dev/null
eq log-prune-no-fork-when-recent "" "$(cat "$STUBLOG")"
agedlog "cli-$(date -v-200H +%Y%m%d_%H%M%S).log" 200
fx env PATH="$T/pstubs:$SP" AGYX_REAL_AGY="$T/fake-agy" FAKE_RUN=true "$AX" --profile p </dev/null 2>/dev/null
eq log-prune-one-find-when-old "find" "$(cat "$STUBLOG")"
eq log-prune-old-removed "3" "$(ls "$(LD)" | wc -l | tr -d ' ')"
# a log that agy keeps writing is not deleted just because its name is old (the find test is the mtime)
rm -rf "$(LD)"; mkdir -p "$(LD)"; agedlog "cli-$(date -v-300H +%Y%m%d_%H%M%S).log" 1
llq >/dev/null
eq log-prune-active-old-name-kept "2" "$(ls "$(LD)" | wc -l | tr -d ' ')"
# the day arithmetic behind the pre-check agrees with date(1)
res=
for d in 19700101 20000229 20240229 20241231 20260101 20261113 20991231; do
  got=$(sh -c '. "$1"; agyx_days "$2"; echo $AGYX_DAYS' sh "$here/runtime/sync.sh" "$d")
  want=$(( $(date -j -u -f %Y%m%d%H%M%S "${d}000000" +%s) / 86400 ))
  [ "$got" = "$want" ] || res="$res $d:$got/$want"
done
eq log-days-arithmetic "" "$res"
# logs are per profile
mkdir -p "$N/data/profiles/q/home"; FAKE_RUN=true; export FAKE_RUN
fx env PATH="$SP" AGYX_REAL_AGY="$T/fake-agy" "$AX" --profile q </dev/null 2>/dev/null; unset FAKE_RUN
eq log-per-profile "1,1,q" "$(ls "$(LD q)"/cli-*.log | wc -l | tr -d ' '),$(ls "$(PD q)"/cli.log | wc -l | tr -d ' '),$(cd "$(PD q)" && cd -P "$(dirname "$(readlink cli.log)")" && basename "$(dirname "$PWD")")"
# doctor shows the log dir and the newest file per profile
d=$(fx env PATH="$SP" AGYX_REAL_AGY="$T/fake-agy" "$AX" doctor </dev/null 2>/dev/null)
eq doctor-logs "1" "$(echo "$d" | grep -c "^  logs: $(LD p)/, newest: $(basename "$(ls -t "$(LD p)"/*.log | head -n 1)")\$")"
rm -rf "$(LD q)"
d=$(fx env PATH="$SP" AGYX_REAL_AGY="$T/fake-agy" "$AX" doctor </dev/null 2>/dev/null)
eq doctor-logs-none "1" "$(echo "$d" | grep -c "^  logs: $(LD q)/, newest: none yet\$")"

echo "passed: $pass, failed: $fail"
[ "$fail" = 0 ]
