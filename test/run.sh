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
# agyx; <data dir>/bin gets the optional bare `agy` link from `agyx shim` below.
PATH=$T/brewbin:$DD/bin:/usr/bin:/bin:/usr/sbin:/sbin
[ -x "$here/bin/agy" ] && [ -x "$here/bin/agyx" ] || { echo "bin/agy, bin/agyx must be executable" >&2; exit 1; }

cat > "$T/fake-agy" <<'EOF'
#!/bin/sh
[ "$1" = --version ] || echo x >> "$LAUNCHLOG"
if [ -n "$FAKE_RUN" ]; then exec sh -c "$FAKE_RUN"; fi
echo "HOME=$HOME"
echo "AGY_PROFILE=$AGY_PROFILE"
echo "ZDOTDIR=${ZDOTDIR-<unset>}"
echo "BASH_ENV=${BASH_ENV-<unset>}"
echo "ORIG_ZDOTDIR=$AGYX_ORIG_ZDOTDIR"
for a in "$@"; do echo "ARG=$a"; done
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
"$T/brewbin/agyx" setup "$T/fake-agy" > "$T/install.out" || { cat "$T/install.out"; exit 1; }
[ ! -e "$DD/bin" ] || { echo "setup must not create bin/" >&2; exit 1; }
"$T/brewbin/agyx" shim > "$T/shim.out" || { cat "$T/shim.out"; exit 1; }
[ "$(command -v agy)" = "$DD/bin/agy" ] || { echo "agy not resolved to $DD/bin/agy" >&2; exit 1; }
for p in work home other; do mkdir -p "$DD/profiles/$p/home"; done
echo work > "$DD/default"

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

# real-agy pointing at the shim is refused
ln -sfn "$here/bin/agy" "$DD/real-agy"
out=$(agy 2>&1); rc=$?
eq refuse-self "1" "$([ $rc -ne 0 ] && echo "$out" | grep -q 'shim itself' && echo 1)"
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
eq launch-bare-help "ARG=--help" "$(agyx --help | grep '^ARG=')"
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
for n in setup doctor shim unshim profile; do
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
tokjson home alice@example.com
tokjson twin alice@example.com
printf '{"token":{"access_token":"SECRET-ACCESS-work","refresh_token":"SECRET-REFRESH-work"},"auth_method":"oauth"}\n' > "$(tokdir work)"
mkdir -p "$DD/profiles/junk/home"; echo 'not json SECRET-JUNK' > "$(tokdir junk)"
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
# setup only records the real agy; management subcommands never launch agy
rm "$DD/real-agy"
eq ctl-setup "real agy: $T/fake-agy" "$(ctl setup "$T/fake-agy" | head -n 1)"
eq ctl-setup-link "$T/fake-agy" "$(readlink "$DD/real-agy")"
eq ctl-setup-shim "1" "$(ctl setup "$here/bin/agy" >/dev/null 2>&1 || echo 1)"
eq ctl-setup-data-shim "1" "$(ctl setup "$DD/bin/agy" >/dev/null 2>&1 || echo 1)"
# setup without an argument skips the shim link and takes the next agy in PATH
mkdir "$T/fakebin"; ln -s "$T/fake-agy" "$T/fakebin/agy"
eq ctl-setup-autodetect "real agy: $T/fakebin/agy" "$(PATH=$DD/bin:$T/fakebin:$PATH ctl setup | head -n 1)"
eq ctl-setup-keeps-shim "$here/bin/agy" "$(readlink "$DD/bin/agy")"
: > "$LAUNCHLOG"
for c in "profile list" "profile default work" doctor "setup $T/fake-agy" shim unshim shim; do
  # shellcheck disable=SC2086
  agyx $c >/dev/null 2>&1
done
eq mgmt-never-launches "0" "$(wc -c < "$LAUNCHLOG" | tr -d ' ')"
# no profiles yet
eq ctl-empty-list "no profiles yet; run: agyx profile login NAME/0" "$(AGYX_DATA_DIR=$T/empty ctl profile list)/$(AGYX_DATA_DIR=$T/empty ctl profile list >/dev/null; echo $?)"
# misuse of a management subcommand prints the usage (exit 2) and never launches agy
: > "$LAUNCHLOG"
res=
for c in "setup a b" "setup $T/nonexistent" profile "profile bogus" "profile login" "profile login Bad" "profile login profile" "profile login a b" "profile default a b" "profile default nope" "profile default profile" "profile list x" "doctor x" "shim x" "unshim x"; do
  # shellcheck disable=SC2086
  out=$(ctl $c 2>&1 >/dev/null); rc=$?
  [ "$rc" = 2 ] && echo "$out" | grep -q '^usage: agyx' || res="$res [$c rc=$rc]"
done
eq ctl-misuse-usage "" "$res"
eq ctl-misuse-no-launch "0" "$(wc -c < "$LAUNCHLOG" | tr -d ' ')"

# agyx subcommands never overlap with the real agy 1.5.6 subcommands/flags
ctl_subs="setup doctor shim unshim profile"
agy_subs="acp agent agents changelog help install mcp mic-serve models plugin plugins remote-control update -h --help"
both=
for a in $ctl_subs; do for b in $agy_subs; do [ "$a" = "$b" ] && both="$both $a"; done; done
eq subcommands-disjoint "" "$both"
eq subcommands-match-script "$ctl_subs" "$(sed -n 's/^  \(setup|.*\)) ;;$/\1/p' "$here/bin/agyx" | tr '|' ' ')"
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
eq ctl-doctor-on "1" "$(ctl doctor | grep -c 'takeover: on')"
eq ctl-doctor-warn "1" "$(PATH=$T/fakebin:$PATH ctl doctor | grep -c 'takeover: WARNING')"

# shim / unshim
ctl unshim >/dev/null
eq ctl-unshim "absent" "$([ -e "$DD/bin/agy" ] || [ -L "$DD/bin/agy" ] || echo absent)"
eq ctl-unshim-keeps-real-agy "ok" "$([ -L "$DD/real-agy" ] && echo ok)"
eq ctl-unshim-idempotent "0" "$(ctl unshim >/dev/null; echo $?)"
eq ctl-doctor-off "1" "$(ctl doctor | grep -c 'takeover: off.*nested .agyx. routes to the inherited profile.*bare .agy. runs the real agy')"
out=$(ctl shim); eq ctl-shim-link "$here/bin/agy" "$(readlink "$DD/bin/agy")"
eq ctl-shim-says-path "1" "$(echo "$out" | grep -c 'must come BEFORE the directory of the real agy')"
eq ctl-shim-idempotent "0" "$(ctl shim >/dev/null; echo $?)"
eq ctl-shim-used "other" "$(agy --profile other | sed -n 's/^AGY_PROFILE=//p')"
ctl unshim >/dev/null
# refusals: never remove or overwrite anything that is not a link to the shim
echo precious > "$DD/bin/agy"
eq ctl-unshim-refuse-file "1" "$(ctl unshim >/dev/null 2>&1 || echo 1)"
eq ctl-shim-refuse-file "1" "$(ctl shim >/dev/null 2>&1 || echo 1)"
eq ctl-refuse-file-intact "precious" "$(cat "$DD/bin/agy")"
rm "$DD/bin/agy"; ln -s "$T/fake-agy" "$DD/bin/agy"
eq ctl-unshim-refuse-other-link "1" "$(ctl unshim >/dev/null 2>&1 || echo 1)"
eq ctl-shim-refuse-other-link "1" "$(ctl shim >/dev/null 2>&1 || echo 1)"
eq ctl-refuse-link-intact "$T/fake-agy" "$(readlink "$DD/bin/agy")"
rm "$DD/bin/agy"

# per-profile keychain (fake security; the real one is never called)
H=$DD/profiles/kc/home K=$DD/profiles/kc/home/Library/Keychains/login.keychain-db
mkdir -p "$H"; : > "$SECLOG"
out=$(agyx --profile kc x)
eq kc-stdout-only-agy "6" "$(echo "$out" | wc -l | tr -d ' ')"
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
snap() { ls -lRA "$@"; }
mkdir -p "$G/antigravity-cli/log" "$G/skills" "$G/skills2" "$G/antigravity-cli/subdir"
echo shared > "$G/settings.json"; echo a > "$G/a.txt"; echo same > "$G/b.txt"
echo old > "$G/c.txt"; touch -t 202001010000 "$G/c.txt"
echo shared-d > "$G/d.txt"; touch -t 202401010000 "$G/d.txt"
echo mcp > "$G/antigravity-cli/mcp.json"
echo R-token > "$G/antigravity-cli/antigravity-oauth-token"; echo R-log > "$G/antigravity-cli/cli.log"
echo R-jb > "$G/antigravity-cli/jetbox_summaries_proto.pb"
S=$DD/profiles/s1/home A=$DD/profiles/s1/home/.gemini/antigravity-cli
mkdir -p "$A/log" "$S/.gemini/skills2"
echo p > "$S/.gemini/skills2/p.txt"   # differs from the shared (empty) directory
ln -s /nonexistent "$S/.gemini/a.txt"                                  # case 3: wrong link
echo same > "$S/.gemini/b.txt"                                         # case 4: identical
echo new-c > "$S/.gemini/c.txt"; touch -t 202401010000 "$S/.gemini/c.txt"   # case 4: profile newer
echo profile-d > "$S/.gemini/d.txt"; touch -t 202001010000 "$S/.gemini/d.txt" # case 4: shared newer
echo only > "$S/.gemini/only-here.txt"; echo extra > "$A/extra.json"  # adoption
echo P-token > "$A/antigravity-oauth-token"; echo P-log > "$A/cli.log"; echo P-jb > "$A/jetbox_summaries_proto.pb"
out=$(launch s1)
eq gem-stdout-empty "" "$out"
eq gem-stderr-lines "3" "$(grep -c . "$T/err")"
eq gem-new-link "link" "$(islink "$S/.gemini/settings.json" "$G/settings.json")"
eq gem-dir-link "link" "$(islink "$S/.gemini/skills" "$G/skills")"
eq gem-nested-link "link" "$(islink "$A/mcp.json" "$G/antigravity-cli/mcp.json")"
eq gem-wrong-link-replaced "link" "$(islink "$S/.gemini/a.txt" "$G/a.txt")"
eq gem-identical-linked "link/same" "$(islink "$S/.gemini/b.txt" "$G/b.txt")/$(cat "$G/b.txt")"
eq gem-profile-newer "link/new-c/old" "$(islink "$S/.gemini/c.txt" "$G/c.txt")/$(cat "$G/c.txt")/$(cat "$S"/agyx-drift/.gemini/c.txt.*)"
eq gem-shared-newer "link/shared-d/profile-d" "$(islink "$S/.gemini/d.txt" "$G/d.txt")/$(cat "$G/d.txt")/$(cat "$S"/agyx-drift/.gemini/d.txt.*)"
eq gem-real-dir-left "dir" "$([ -d "$S/.gemini/skills2" ] && [ ! -L "$S/.gemini/skills2" ] && echo dir)"
eq gem-real-dir-warned "1" "$(grep -c 'skills2 is a real directory' "$T/err")"
eq gem-adopt-file "link/only" "$(islink "$S/.gemini/only-here.txt" "$G/only-here.txt")/$(cat "$G/only-here.txt")"
eq gem-adopt-nested "link/extra" "$(islink "$A/extra.json" "$G/antigravity-cli/extra.json")/$(cat "$G/antigravity-cli/extra.json")"
eq gem-real-dirs "dir dir" "$([ -d "$S/.gemini" ] && [ ! -L "$S/.gemini" ] && printf dir) $([ -d "$A" ] && [ ! -L "$A" ] && echo dir)"
eq gem-private-kept "P-token P-log P-jb" "$(cat "$A/antigravity-oauth-token") $(cat "$A/cli.log") $(cat "$A/jetbox_summaries_proto.pb")"
eq gem-private-regular "reg reg reg dir" "$(for f in antigravity-oauth-token cli.log jetbox_summaries_proto.pb; do [ -f "$A/$f" ] && [ ! -L "$A/$f" ] && printf 'reg '; done)$([ -d "$A/log" ] && [ ! -L "$A/log" ] && echo dir)"
eq gem-private-shared-untouched "R-token R-log R-jb" "$(cat "$G/antigravity-cli/antigravity-oauth-token") $(cat "$G/antigravity-cli/cli.log") $(cat "$G/antigravity-cli/jetbox_summaries_proto.pb")"
# second launch changes nothing (only the real-directory warning repeats)
before=$(snap "$S" "$G"); out=$(launch s1); after=$(snap "$S" "$G")
eq gem-second-launch-same "$before" "$after"
eq gem-second-launch-stderr "1" "$(grep -c . "$T/err")"
eq gem-second-launch-stdout "" "$out"
# R/.gemini/antigravity-cli is created when adopting into a real home that lacks it
R2=$T/real2; mkdir -p "$R2"; mkdir -p "$DD/profiles/s2/home/.gemini/antigravity-cli"
echo e2 > "$DD/profiles/s2/home/.gemini/antigravity-cli/extra.json"
(AGYX_REAL_HOME=$R2 launch s2 >/dev/null)
eq gem-creates-shared-dir "link/e2" "$(islink "$DD/profiles/s2/home/.gemini/antigravity-cli/extra.json" "$R2/.gemini/antigravity-cli/extra.json")/$(cat "$R2/.gemini/antigravity-cli/extra.json")"
# a clean profile: a launch is a no-op when everything is already correct
mkdir -p "$DD/profiles/s3/home"; launch s3 >/dev/null
S3=$DD/profiles/s3/home
before=$(snap "$S3" "$G"); launch s3 >/dev/null; after=$(snap "$S3" "$G")
eq gem-noop-same "$before" "$after"
eq gem-noop-stderr "0" "$(grep -c . "$T/err")"

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
eq wl-conflict-silent "0" "$(grep -c . "$T/err")"
eq wl-missing-not-linked "absent" "$([ -e "$S4/.npm" ] || [ -L "$S4/.npm" ] || echo absent)"
mkdir "$RH/.cache"; launch s4 >/dev/null
eq wl-later-linked "link" "$(islink "$S4/.cache" "$RH/.cache")"
rmdir "$RH/.cache"; launch s4 >/dev/null
eq wl-dangling-removed "gone" "$([ -L "$S4/.cache" ] || [ -e "$S4/.cache" ] || echo gone)"
# doctor reports (section of profile s4 / s1)
sect() { ctl doctor | awk -v p="$1:" '/^profile /{on=($2==p)} on'; }
eq wl-doctor "1 1 1 1" "$(sect s4 | grep -c 'symlinks .gitconfig: linked') $(sect s4 | grep -c 'symlinks .ssh: CONFLICT') $(sect s4 | grep -c 'symlinks .npm: missing in the real home') $(sect s4 | grep -c 'symlinks .config: CONFLICT')"
eq gem-doctor "1 1" "$(sect s1 | grep -c 'shared .gemini/skills2: real directory in the profile') $(sect s1 | grep -c 'agyx-drift: 2 file(s)')"
eq gem-doctor-clean "0" "$(sect s3 | grep -c 'shared ')"
# list file: comments, blanks, whitespace, invalid names
mkdir -p "$RH/.local" "$RH/mydir2"
mkdir -p "$(dirname "$HL")"; printf '# comment\n\n   # indented comment\n  .gitconfig  \n../etc\na/b\n.gemini\nLibrary\n.local\n.\n..\nmydir2\n' > "$HL"
S5=$DD/profiles/s5/home; mkdir -p "$S5"
launch s5 >/dev/null
eq wl-file-valid "link link" "$(islink "$S5/.gitconfig" "$RH/.gitconfig") $(islink "$S5/mydir2" "$RH/mydir2")"
eq wl-file-invalid-warned "7" "$(grep -c "symlinks: skipping invalid name" "$T/err")"
eq wl-file-not-linked ".local absent, .gemini real" "$([ -e "$S5/.local" ] || [ -L "$S5/.local" ] || printf '.local absent,') $([ -d "$S5/.gemini" ] && [ ! -L "$S5/.gemini" ] && echo .gemini real)"
eq wl-library-not-link "no" "$([ -L "$S5/Library" ] && echo yes || echo no)"
# profile default: show (or none) and set
rm -f "$DD/default"
eq default-none "none/0" "$(ctl profile default)/$(ctl profile default >/dev/null; echo $?)"
(ctl profile default other >/dev/null)
eq default-shown "other/other" "$(ctl profile default)/$(cat "$DD/default")"
eq default-launch-uses-it "other" "$(agyx 2>/dev/null | sed -n 's/^AGY_PROFILE=//p')"
eq default-use-gone "1" "$(ctl profile use other >/dev/null 2>&1 || echo 1)"
printf work > "$DD/default"
# setup writes the default list once and never overwrites it
D2=$T/d2 RH3=$T/rh3
(AGYX_REAL_HOME=$RH3 AGYX_DATA_DIR=$D2 ctl setup "$T/fake-agy" >/dev/null)
L3=$RH3/.config/agyx/symlinks
eq setup-writes-list ".gitconfig .ssh .config .npm .npmrc .bun .bunfig.toml .cache .cargo .rustup go Code GitHub " "$(grep -v '^#' "$L3" | tr '\n' ' ')"
eq setup-not-in-data-dir "absent" "$([ -e "$D2/symlinks" ] || echo absent)"
echo mine > "$L3"; (AGYX_REAL_HOME=$RH3 AGYX_DATA_DIR=$D2 ctl setup "$T/fake-agy" >/dev/null)
eq setup-keeps-list "mine" "$(cat "$L3")"
rm -rf "${DD:?}/profiles/s1" "${DD:?}/profiles/s2" "${DD:?}/profiles/s3" "${DD:?}/profiles/s4" "${DD:?}/profiles/s5"

# a real directory identical to the shared one is moved to agyx-drift and replaced by the link
rm -f "$HL"   # drop the invalid-names list left by the whitelist tests
mkdir -p "$G/antigravity-cli/mcp/t3-code"; echo '{"a":1}' > "$G/antigravity-cli/mcp/t3-code/a.json"
S6=$DD/profiles/s6/home
mkdir -p "$S6/.gemini/antigravity-cli/mcp/t3-code"; echo '{"a":1}' > "$S6/.gemini/antigravity-cli/mcp/t3-code/a.json"
out=$(launch s6)
eq dir-identical-silent "0" "$(grep -c . "$T/err")"
eq dir-identical-linked "link" "$(islink "$S6/.gemini/antigravity-cli/mcp" "$G/antigravity-cli/mcp")"
eq dir-identical-kept "{\"a\":1}" "$(cat "$S6"/agyx-drift/.gemini/antigravity-cli/mcp.*/t3-code/a.json)"
before=$(snap "$S6" "$G"); launch s6 >/dev/null; after=$(snap "$S6" "$G")
eq dir-identical-second-launch "$before/0" "$after/$(grep -c . "$T/err")"
rm -rf "${DD:?}/profiles/s6" "$G/antigravity-cli/mcp"

# logged in via the profile keychain (item gemini/antigravity) and email from agy's log
mklk() { h=$DD/profiles/$1/home; mkdir -p "$h/Library/Keychains" "$h/.gemini/antigravity-cli/log"; : > "$h/Library/Keychains/login.keychain-db"; echo "$h"; }
loglines() { printf '%s\n' "$@"; }
h=$(mklk lk1); : > "$h/.fake-item"; L=$h/.gemini/antigravity-cli/log
loglines '10:00 applyAuthResult ok email=old@example.com' > "$L/a.log"; touch -t 202001010000 "$L/a.log"
loglines '11:00 applyAuthResult ok email=first@example.com scopes=x' '11:01 applyAuthResult ok email=last@example.com' '11:02 other email=ignored@example.com' > "$L/b.log"; touch -t 202401010000 "$L/b.log"
h=$(mklk lk2); : > "$h/.fake-item"
h=$(mklk lk3); : > "$h/.fake-item"; tokjson lk3 tok@example.com
loglines '11:00 applyAuthResult ok email=log@example.com' > "$h/.gemini/antigravity-cli/log/c.log"
h=$(mklk lk4); : > "$h/.fake-item"; printf '{"token":{"access_token":"SECRET-ACCESS-lk4"},"auth_method":"oauth"}\n' > "$(tokdir lk4)"
loglines '11:00 applyAuthResult ok email=fromlog@example.com' > "$h/.gemini/antigravity-cli/log/d.log"
h=$(mklk lk5); loglines '11:00 applyAuthResult ok email=nobody@example.com' > "$h/.gemini/antigravity-cli/log/e.log"
h=$(mklk lk6); : > "$h/.fake-item"; loglines '12:00 applyAuthResult ok email=last@example.com' > "$h/.gemini/antigravity-cli/log/f.log"
: > "$SECLOG"
lst=$(ctl profile list)
row() { echo "$lst" | grep "^$1 " | sed 's/  */ /g'; }
eq lk-newest-log-last-email "lk1 last@example.com" "$(row lk1)"
eq lk-keychain-no-email "lk2 logged in, email unknown" "$(row lk2)"
eq lk-token-email-wins "lk3 tok@example.com" "$(row lk3)"
eq lk-token-without-field-uses-log "lk4 fromlog@example.com" "$(row lk4)"
eq lk-no-item-no-token "lk5 not logged in" "$(row lk5)"
eq lk-dup-warning "1" "$(echo "$lst" | grep -c 'WARNING: profiles lk1 lk6 are logged in to the same Google account (last@example.com)')"
eq lk-doctor "1" "$(ctl doctor | grep -c '^profile lk1: last@example.com, home ')"
K=$DD/profiles/lk1/home/Library/Keychains/login.keychain-db
eq lk-find-call "HOME=$DD/profiles/lk1/home find-generic-password -s gemini -a antigravity $K" "$(grep 'HOME=[^ ]*/lk1/home find-generic' "$SECLOG" | head -n 1)"
eq lk-never-secret "0" "$(grep find-generic-password "$SECLOG" | grep -c -e ' -w' -e ' -g')"
eq lk-no-secrets-printed "0" "$( (echo "$lst"; ctl doctor) | grep -c SECRET)"
for n in lk1 lk2 lk3 lk4 lk5 lk6; do rm -rf "${DD:?}/profiles/$n"; done

# whitelist file location: ${XDG_CONFIG_HOME:-<real home>/.config}/agyx/symlinks
RH4=$T/rh4 XDG=$T/xdg
(AGYX_REAL_HOME=$RH4 XDG_CONFIG_HOME=$XDG AGYX_DATA_DIR=$T/d3 ctl setup "$T/fake-agy" >/dev/null)
eq xdg-abs-written "present/absent" "$([ -f "$XDG/agyx/symlinks" ] && echo present)/$([ -e "$RH4/.config/agyx/symlinks" ] || echo absent)"
mkdir -p "$T/cwd"
(cd "$T/cwd" && AGYX_REAL_HOME=$RH4 XDG_CONFIG_HOME=relative/dir AGYX_DATA_DIR=$T/d3 ctl setup "$T/fake-agy" >/dev/null)
eq xdg-relative-ignored "present/absent" "$([ -f "$RH4/.config/agyx/symlinks" ] && echo present)/$([ -e "$T/cwd/relative" ] || echo absent)"
(AGYX_REAL_HOME=$RH4 XDG_CONFIG_HOME=$XDG AGYX_DATA_DIR=$T/d3 ctl doctor | grep -c "^symlinks: $XDG/agyx/symlinks\$") > "$T/n"
eq doctor-links-path "1" "$(cat "$T/n")"
eq doctor-links-path-missing "1" "$(rm -f "$HL"; ctl doctor | grep -c "^symlinks: $HL (missing")"
# launch uses that file; the old <data>/symlinks is no longer read
mkdir -p "$RH/mydir2" "$RH/ignored-by-xdg" "$XDG/agyx"
echo mydir2 > "$XDG/agyx/symlinks"
echo ignored-by-xdg > "$DD/symlinks"
S7=$DD/profiles/s7/home; mkdir -p "$S7"
(XDG_CONFIG_HOME=$XDG launch s7 >/dev/null)
eq xdg-launch-uses-file "link/absent/absent" "$(islink "$S7/mydir2" "$RH/mydir2")/$([ -e "$S7/.gitconfig" ] || echo absent)/$([ -e "$S7/ignored-by-xdg" ] || echo absent)"
rm -rf "${DD:?}/profiles/s7"; rm -f "$DD/symlinks"

# SQLite sidecars (-wal/-shm/-journal) are never linked, adopted or reported; doctor explains identical dirs
echo db > "$G/antigravity-cli/conv.db"
for s in -wal -shm -journal; do echo x > "$G/antigravity-cli/conv.db$s"; done
echo top > "$G/top.sqlite-shm"
S8=$DD/profiles/s8/home A8=$DD/profiles/s8/home/.gemini/antigravity-cli
mkdir -p "$A8" "$G/antigravity-cli/idm" "$A8/idm" "$G/antigravity-cli/dif" "$A8/dif"
echo mine > "$A8/own.db-wal"                                     # profile-only sidecar
echo 1 > "$G/antigravity-cli/idm/a"; echo 1 > "$A8/idm/a"        # identical directory
echo 1 > "$G/antigravity-cli/dif/a"; echo 2 > "$A8/dif/a"        # different directory
eq doctor-identical-dir "1" "$(sect s8 | grep -c 'antigravity-cli/idm: real directory, identical, replaced by a link on next launch')"
eq doctor-different-dir "1" "$(sect s8 | grep -c 'antigravity-cli/dif: real directory in the profile (not merged)')"
eq doctor-skips-sidecars-before "0" "$(sect s8 | grep -c -e '-wal' -e '-shm' -e '-journal')"
launch s8 >/dev/null
eq sidecar-launch-stderr "1" "$(grep -c . "$T/err")"
eq sidecar-db-linked "link" "$(islink "$A8/conv.db" "$G/antigravity-cli/conv.db")"
eq sidecars-not-linked "absent" "$(for s in -wal -shm -journal; do [ -e "$A8/conv.db$s" ] || [ -L "$A8/conv.db$s" ] && echo present; done; [ -e "$S8/.gemini/top.sqlite-shm" ] || [ -L "$S8/.gemini/top.sqlite-shm" ] || echo absent)"
eq sidecar-not-adopted "regular/absent" "$([ -f "$A8/own.db-wal" ] && [ ! -L "$A8/own.db-wal" ] && echo regular)/$([ -e "$G/antigravity-cli/own.db-wal" ] || echo absent)"
eq sidecar-no-drift "0" "$(find "$S8/agyx-drift" -name '*-wal*' -o -name '*-shm*' -o -name '*-journal*' 2>/dev/null | grep -c .)"
eq identical-dir-replaced "link" "$(islink "$A8/idm" "$G/antigravity-cli/idm")"
eq doctor-skips-sidecars-after "0" "$(sect s8 | grep -c -e '-wal' -e '-shm' -e '-journal')"
rm -rf "${DD:?}/profiles/s8"

echo "passed: $pass, failed: $fail"
[ "$fail" = 0 ]
