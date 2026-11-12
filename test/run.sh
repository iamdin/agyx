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
# nested calls inside an agent shell route to the inherited profile (agyx, and bare agy when shimmed)
eq nested-agyx "other" "$(FAKE_RUN='FAKE_RUN= agyx x' agyx --profile other | sed -n 's/^AGY_PROFILE=//p')"
eq nested-agy "other" "$(FAKE_RUN='FAKE_RUN= agy x' agyx --profile other | sed -n 's/^AGY_PROFILE=//p')"
eq nested-agyx-switch "home" "$(FAKE_RUN='FAKE_RUN= agyx --profile home x' agyx --profile other | sed -n 's/^AGY_PROFILE=//p')"
# profile names equal to an agyx subcommand are rejected, even if the directory exists
res=
for n in setup login use list doctor shim unshim; do
  mkdir -p "$DD/profiles/$n/home"; : > "$LAUNCHLOG"
  agyx --profile "$n" >/dev/null 2>&1 && res="$res launched:$n"
  agy --profile "$n" >/dev/null 2>&1 && res="$res shim-launched:$n"
  "$here/bin/agyx" login "$n" >/dev/null 2>&1 && res="$res login:$n"
  "$here/bin/agyx" use "$n" >/dev/null 2>&1 && res="$res use:$n"
  [ -s "$LAUNCHLOG" ] && res="$res log:$n"
  rm -rf "${DD:?}/profiles/$n"
done
eq reserved-names "" "$res"

# agyx
ctl() { "$here/bin/agyx" "$@"; }
eq ctl-use "home" "$(ctl use home; cat "$DD/default")"
eq ctl-use-bad "1" "$(ctl use nope 2>/dev/null || echo 1)"
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
want=$(printf '%-12s %s\n' home 'alice@example.com  (default)' junk 'token file present, email unknown' other 'not logged in' twin 'alice@example.com' work 'token file present, email unknown')
eq ctl-list "$want${nl}$dupline" "$(ctl list)"
eq ctl-doctor-email "1" "$(ctl doctor | grep -c '^profile home: alice@example.com, home ')"
eq ctl-doctor-not-logged-in "1" "$(ctl doctor | grep -c '^profile other: not logged in, home ')"
eq ctl-doctor-unknown "2" "$(ctl doctor | grep -c '^profile \(work\|junk\): token file present, email unknown, home ')"
eq ctl-doctor-dup "1" "$(ctl doctor | grep -cF "$dupline")"
eq ctl-no-token-strings "0" "$( (ctl list; ctl doctor) | grep -c SECRET)"
rm -rf "${DD:?}/profiles/twin" "${DD:?}/profiles/junk"
eq ctl-list-no-dup "0" "$(ctl list | grep -c WARNING)"
eq ctl-login-bad "1" "$(ctl login Bad 2>/dev/null || echo 1)"
eq ctl-login "PROFILE=newp" "$(FAKE_RUN='echo PROFILE=$AGY_PROFILE' ctl login newp)"
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
for c in list "use work" doctor "setup $T/fake-agy" shim unshim shim; do
  # shellcheck disable=SC2086
  agyx $c >/dev/null 2>&1
done
eq mgmt-never-launches "0" "$(wc -c < "$LAUNCHLOG" | tr -d ' ')"
# misuse of a management subcommand prints the usage (exit 2) and never launches agy
: > "$LAUNCHLOG"
res=
for c in "setup a b" "setup $T/nonexistent" login "login Bad" "login list" "login a b" use "use nope" "use list" "list x" "doctor x" "shim x" "unshim x"; do
  # shellcheck disable=SC2086
  out=$(ctl $c 2>&1 >/dev/null); rc=$?
  [ "$rc" = 2 ] && echo "$out" | grep -q '^usage: agyx' || res="$res [$c rc=$rc]"
done
eq ctl-misuse-usage "" "$res"
eq ctl-misuse-no-launch "0" "$(wc -c < "$LAUNCHLOG" | tr -d ' ')"

# agyx subcommands never overlap with the real agy 1.5.6 subcommands/flags
ctl_subs="setup login use list doctor shim unshim"
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

echo "passed: $pass, failed: $fail"
[ "$fail" = 0 ]
