#!/bin/sh
# Self-contained tests; uses a fake agy, never the real one.
here=$(cd "$(dirname "$0")/.." && pwd -P)
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
DD=$T/data RH=$T/realhome
mkdir -p "$DD/profiles" "$RH"
export AGYCTL_DATA_DIR=$DD AGYCTL_REAL_HOME=$RH HOME=$RH
unset AGY_PROFILE ZDOTDIR BASH_ENV AGYCTL_ORIG_ZDOTDIR_SET AGYCTL_ORIG_ZDOTDIR AGYCTL_ORIG_BASH_ENV_SET AGYCTL_ORIG_BASH_ENV
# Minimal PATH so the real agy can never be found. Only <data dir>/bin (created by
# `agyctl install` below, via a Homebrew-style symlink to agyctl) holds `agy`.
PATH=$DD/bin:/usr/bin:/bin:/usr/sbin:/sbin
[ -x "$here/bin/agy" ] && [ -x "$here/bin/agyctl" ] || { echo "bin/agy, bin/agyctl must be executable" >&2; exit 1; }

cat > "$T/fake-agy" <<'EOF'
#!/bin/sh
if [ -n "$FAKE_RUN" ]; then exec sh -c "$FAKE_RUN"; fi
echo "HOME=$HOME"
echo "AGY_PROFILE=$AGY_PROFILE"
echo "ZDOTDIR=${ZDOTDIR-<unset>}"
echo "BASH_ENV=${BASH_ENV-<unset>}"
echo "ORIG_ZDOTDIR=$AGYCTL_ORIG_ZDOTDIR"
for a in "$@"; do echo "ARG=$a"; done
EOF
chmod +x "$T/fake-agy"
mkdir "$T/brewbin"; ln -s "$here/bin/agyctl" "$T/brewbin/agyctl"
"$T/brewbin/agyctl" install "$T/fake-agy" > "$T/install.out" || { cat "$T/install.out"; exit 1; }
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
eq flag-over-env "other" "$(AGY_PROFILE=home prof --account other)"
eq flag-equals "other" "$(AGY_PROFILE=home prof --account=other)"
eq home-dir "HOME=$DD/profiles/other/home" "$(agy --account other | grep ^HOME=)"
eq no-default-file-env-only "home" "$(mv "$DD/default" "$T/d"; AGY_PROFILE=home prof; mv "$T/d" "$DD/default")"

# errors: nonzero, message on stderr, nothing on stdout (never falls back)
bad() { # name args...
  n=$1; shift
  out=$(AGY_PROFILE=work agy "$@" 2>"$T/err"); rc=$?
  eq "err-$n" "nonzero,empty-stdout,has-stderr" \
    "$([ $rc -ne 0 ] && echo nonzero),$([ -z "$out" ] && echo empty-stdout),$([ -s "$T/err" ] && echo has-stderr)"
}
bad missing-value --account
bad empty-eq --account=
bad empty-arg --account ""
bad repeated --account work --account other
bad repeated-eq --account=work --account=other
bad uppercase --account Work
bad digit-first --account 1x
bad too-long --account abcdefghijklmnopqrstuvwxyzabcdefg
bad bad-chars "--account=a/b"
bad no-profile-dir --account nope
bad env-no-dir-fallback --account nope x
out=$(AGY_PROFILE=BAD agy 2>&1); eq env-invalid "1" "$([ -n "$out" ] && ! echo "$out" | grep -q HOME= && echo 1)"
out=$(AGY_PROFILE=nope agy 2>&1); eq env-no-dir "1" "$([ -n "$out" ] && ! echo "$out" | grep -q HOME= && echo 1)"
mv "$DD/default" "$T/d"
out=$(agy 2>&1); rc=$?
eq no-default "1" "$([ $rc -ne 0 ] && ! echo "$out" | grep -q HOME= && echo 1)"
mv "$T/d" "$DD/default"

# argv preserved
eq argv "ARG=hello world${nl}ARG=${nl}ARG=--account${nl}ARG=b${nl}ARG=--${nl}ARG=x" \
  "$(args --account other "hello world" "" --account b -- x)"
eq dashdash-consumed "ARG=--account${nl}ARG=b" "$(args --account other -- --account b)"
eq dashdash-no-flag "ARG=--account${nl}ARG=b" "$(AGY_PROFILE=home args -- --account b)"
eq prompt-account-untouched "work ARG=-p${nl}ARG=--account${nl}ARG=zzz" "work $(args -p --account zzz)"
eq no-args "" "$(args)"

# bridge: run `$1` (shell snippet) inside the shim environment
inshim() { FAKE_RUN=$1 agy --account other; }
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

# nested: bare agy inside a bridged shell keeps the profile; --account switches
if command -v zsh >/dev/null; then
  eq nested-same "other" "$(inshim "zsh -c 'FAKE_RUN= agy x'" | sed -n 's/^AGY_PROFILE=//p')"
  eq nested-switch "home" "$(inshim "zsh -c 'FAKE_RUN= agy --account home x'" | sed -n 's/^AGY_PROFILE=//p')"
  eq nested-home "HOME=$DD/profiles/other/home" "$(inshim "zsh -c 'FAKE_RUN= agy x'" | grep ^HOME=)"
  eq nested-originals "ORIG_ZDOTDIR=/zd" "$(ZDOTDIR=/zd inshim "zsh -c 'FAKE_RUN= agy x'" | grep ^ORIG_ZDOTDIR=)"
fi
# direct nested call (ZDOTDIR/BASH_ENV still point at the bridge): saved originals survive
eq nested-direct "orig-zd=/zd orig-be=/be set=1" "$(ZDOTDIR=$here/runtime/zsh BASH_ENV=$here/runtime/bash_env \
  AGYCTL_ORIG_ZDOTDIR_SET=1 AGYCTL_ORIG_ZDOTDIR=/zd AGYCTL_ORIG_BASH_ENV_SET=1 AGYCTL_ORIG_BASH_ENV=/be \
  FAKE_RUN='echo orig-zd=$AGYCTL_ORIG_ZDOTDIR orig-be=$AGYCTL_ORIG_BASH_ENV set=$AGYCTL_ORIG_ZDOTDIR_SET' agy --account home)"

# real-agy pointing at the shim is refused
ln -sfn "$here/bin/agy" "$DD/real-agy"
out=$(agy 2>&1); rc=$?
eq refuse-self "1" "$([ $rc -ne 0 ] && echo "$out" | grep -q 'shim itself' && echo 1)"
ln -sfn "$T/fake-agy" "$DD/real-agy"

# agyctl
ctl() { "$here/bin/agyctl" "$@"; }
eq ctl-use "home" "$(ctl use home; cat "$DD/default")"
eq ctl-use-bad "1" "$(ctl use nope 2>/dev/null || echo 1)"
mkdir -p "$DD/profiles/home/home/.gemini/antigravity-cli"; : > "$DD/profiles/home/home/.gemini/antigravity-cli/antigravity-oauth-token"
eq ctl-list "* home  token file present${nl}  other  no token file${nl}  work  no token file" "$(ctl list)"
eq ctl-login-bad "1" "$(ctl login Bad 2>/dev/null || echo 1)"
eq ctl-login "PROFILE=newp" "$(FAKE_RUN='echo PROFILE=$AGY_PROFILE' ctl login newp)"
eq ctl-login-mode "drwx------" "$(ls -ld "$DD/profiles/newp/home" | cut -c1-10)"
rm "$DD/real-agy" "$DD/bin/agy"
eq ctl-install "real agy: $T/fake-agy" "$(ctl install "$T/fake-agy" | head -n 1)"
eq ctl-install-link "$T/fake-agy" "$(readlink "$DD/real-agy")"
eq ctl-install-shim-link "$here/bin/agy" "$(readlink "$DD/bin/agy")"
eq ctl-install-path-line "  export PATH=\"$DD/bin:\$PATH\"" "$(ctl install "$T/fake-agy" | tail -n 1)"
eq ctl-install-shim "1" "$(ctl install "$here/bin/agy" >/dev/null 2>&1 || echo 1)"
eq ctl-install-data-shim "1" "$(ctl install "$DD/bin/agy" >/dev/null 2>&1 || echo 1)"
# install without an argument skips the shim and takes the next agy in PATH
mkdir "$T/fakebin"; ln -s "$T/fake-agy" "$T/fakebin/agy"
eq ctl-install-autodetect "real agy: $T/fakebin/agy" "$(PATH=$DD/bin:$T/fakebin:$PATH ctl install | head -n 1)"
eq ctl-help "0" "$(ctl --help >/dev/null; echo $?)"
eq ctl-doctor "1" "$(ctl doctor | grep -c 'resolves to the shim')"
eq ctl-doctor-not-first "1" "$(PATH=$T/fakebin:$PATH ctl doctor | grep -c 'does NOT resolve')"
eq ctl-doctor-no-token-content "0" "$(ctl doctor | grep -c secret)"

echo "passed: $pass, failed: $fail"
[ "$fail" = 0 ]
