#!/bin/sh
# Tests for scripts/release.sh in throwaway git repos with stubbed gh, brew, curl, shellcheck
# and local bare repositories as origin: no network. Run: sh test/release.sh
here=$(cd "$(dirname "$0")/.." && pwd -P)
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL=$T/gitconfig GIT_CONFIG_NOSYSTEM=1
printf '[user]\n\tname = Test\n\temail = dev@users.noreply.example.com\n[init]\n\tdefaultBranch = main\n[commit]\n\tgpgsign = false\n[tag]\n\tgpgsign = false\n' > "$GIT_CONFIG_GLOBAL"

mkdir "$T/stubs"
cat > "$T/stubs/shellcheck" <<'EOF'
#!/bin/sh
echo "shellcheck $*" >> "$STUBLOG"
exit "${STUB_SC:-0}"
EOF
cat > "$T/stubs/gh" <<'EOF'
#!/bin/sh
echo "gh $*" >> "$STUBLOG"
EOF
cat > "$T/stubs/brew" <<'EOF'
#!/bin/sh
echo "brew $*" >> "$STUBLOG"
EOF
cat > "$T/stubs/curl" <<'EOF'
#!/bin/sh
echo "curl $*" >> "$STUBLOG"
while [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; shift; done
printf 'tarball' > "$out"
EOF
chmod +x "$T/stubs/shellcheck" "$T/stubs/gh" "$T/stubs/brew" "$T/stubs/curl"
export STUBLOG=$T/stublog
PATH=$T/stubs:$PATH
if command -v shasum >/dev/null 2>&1; then SHA=$(printf 'tarball' | shasum -a 256 | cut -d' ' -f1)
else SHA=$(printf 'tarball' | sha256sum | cut -d' ' -f1)
fi

pass=0 fail=0
eq() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3"; fi; }

# mk: fresh origin + work repo ($W) at version 0.1.3 and a tap ($T/homebrew-tap) with its origin
mk() {
  rm -rf "$T/env"; mkdir -p "$T/env"; E=$T/env; W=$E/repo; : > "$STUBLOG"
  git init -q --bare "$E/origin.git"; git init -q --bare "$E/tap-origin.git"
  git clone -q "$E/origin.git" "$W" 2>/dev/null; git clone -q "$E/tap-origin.git" "$E/homebrew-tap" 2>/dev/null
  mkdir -p "$W/scripts" "$W/runtime" "$W/test" "$W/Formula"
  cp "$here/scripts/release.sh" "$W/scripts/release.sh"
  printf 'AGYX_VERSION=0.1.3 # x\n' > "$W/runtime/sync.sh"
  printf 'exit 0\n' > "$W/test/run.sh"
  printf 'class Agyx < Formula\n  url "https://github.com/iamdin/agyx/archive/refs/tags/v0.1.3.tar.gz"\n  # PLACEHOLDER: fill in\n  sha256 "0000000000000000000000000000000000000000000000000000000000000000"\nend\n' > "$W/Formula/agyx.rb"
  git -C "$W" add -A; git -C "$W" commit -q -m first; git -C "$W" tag v0.1.2; git -C "$W" push -q origin main --tags 2>/dev/null
  echo x > "$W/more"; git -C "$W" add more; git -C "$W" commit -q -m second; git -C "$W" push -q origin main
  echo y > "$E/homebrew-tap/README"; git -C "$E/homebrew-tap" add README; git -C "$E/homebrew-tap" commit -q -m init; git -C "$E/homebrew-tap" push -q origin main 2>/dev/null
  TAPHEAD=$(git -C "$E/homebrew-tap" rev-parse HEAD); ORIGHEAD=$(git -C "$E/origin.git" rev-parse main)
}
rel() { (cd "$W" && sh scripts/release.sh "$@" >"$T/out" 2>&1 </dev/null); }
untouched() { # nothing pushed, published or written to the tap (origin main moves only where a test pushes itself)
  [ -z "$(git -C "$E/origin.git" tag -l v0.1.3)" ] && [ "$(git -C "$E/tap-origin.git" rev-parse main)" = "$TAPHEAD" ] \
    && ! grep -q '^gh\|^brew\|^curl' "$STUBLOG" && echo untouched || echo CHANGED
}
refuses() { # name args...: exits 1, says Refusing, changes nothing
  _n=$1; shift; rel "$@"; _rc=$?
  eq "$_n" "1,refused,untouched" "$_rc,$(grep -q '^Refusing to release' "$T/out" && echo refused),$(untouched)"
}

# bad arguments
mk
rel; eq args-none "2" "$?"
rel 1.2; eq args-bad-version "2" "$?"
rel --bogus 0.1.3; eq args-bad-flag "2" "$?"
rel 0.1.3 0.1.4; eq args-two-versions "2" "$?"

# dry run: passes every check, prints every command, changes nothing, never asks
mk; rel --dry-run 0.1.3; rc=$?
eq dry-run-exit "0" "$rc"
eq dry-run-untouched "untouched,$ORIGHEAD,none" "$(untouched),$(git -C "$E/origin.git" rev-parse main),$(git -C "$W" tag -l v0.1.3 | grep . || echo none)"
eq dry-run-commands "1,1,1,1,1,1" "$(grep -c '+ git tag -a v0.1.3' "$T/out"),$(grep -c '+ gh release create v0.1.3 --generate-notes$' "$T/out"),$(grep -c 'push origin main v0.1.3' "$T/out"),$(grep -c 'brew audit --strict --online iamdin/tap/agyx' "$T/out"),$(grep -c "would ask 'Release 0.1.3? \[y/N\]'" "$T/out"),$(grep -c 'commit -q -m agyx 0.1.3' "$T/out")"
eq dry-run-no-changelog "0" "$(grep -ci changelog "$T/out")"
eq dry-run-ran-checks "1,1" "$(grep -c '^shellcheck ' "$STUBLOG"),$(grep -c 'ok   shellcheck' "$T/out")"
eq dry-run-no-install "0" "$(grep -c 'brew install' "$STUBLOG")"

# each failed check refuses and changes nothing
mk; git -C "$W" switch -q -c feature; refuses check-not-main 0.1.3
mk; printf 'AGYX_VERSION=0.1.4\n' > "$W/runtime/sync.sh"; git -C "$W" commit -q -am v; git -C "$W" push -q origin main; refuses check-agyx-version 0.1.3
mk; sed -i.bak 's/v0.1.3.tar/v0.1.4.tar/' "$W/Formula/agyx.rb"; rm "$W/Formula/agyx.rb.bak"; git -C "$W" commit -q -am f; git -C "$W" push -q origin main; refuses check-formula-tag 0.1.3
mk; git -C "$W" tag v0.1.3; refuses check-tag-exists 0.1.3
mk; printf 'exit 1\n' > "$W/test/run.sh"; git -C "$W" commit -q -am t; git -C "$W" push -q origin main; refuses check-tests-fail 0.1.3
mk; export STUB_SC=1; refuses check-shellcheck-fails 0.1.3; unset STUB_SC
mk; export AGYX_TAP_DIR=$E/nope; refuses check-tap-missing 0.1.3; unset AGYX_TAP_DIR
# non-code state is not checked: dirty tree, behind/ahead of origin, a foreign commit email, a dirty tap, no changelog
mk; echo z >> "$W/more"; echo z > "$W/untracked"; echo z > "$E/homebrew-tap/dirty"
git -C "$W" -c user.email=me@example.com commit -q --allow-empty -m other
rel --dry-run 0.1.3; eq not-checked-dirty-foreign-email "0,0" "$?,$(grep -ci 'email\|changelog\|clean' "$T/out")"
mk; git -C "$W" reset -q --hard HEAD~1; rel --dry-run 0.1.3; eq not-checked-behind-origin "0" "$?"

# real run: answering no cancels
mk; printf 'n\n' > "$E/ans"
(cd "$W" && AGYX_TTY=$E/ans sh scripts/release.sh 0.1.3 >"$T/out" 2>&1 </dev/null); rc=$?
eq real-no "1,cancelled,untouched" "$rc,$(grep -c 'Cancelled' "$T/out" | sed 's/1/cancelled/'),$(untouched)"
mk; : > "$E/ans"
(cd "$W" && AGYX_TTY=$E/ans sh scripts/release.sh 0.1.3 >"$T/out" 2>&1 </dev/null); rc=$?
eq real-eof "1,untouched" "$rc,$(untouched)"
# real run: yes tags, pushes, creates the release, writes the tap formula, audits
mk; printf 'y\n' > "$E/ans"
(cd "$W" && AGYX_TTY=$E/ans sh scripts/release.sh 0.1.3 >"$T/out" 2>&1 </dev/null); rc=$?
eq real-exit "0" "$rc"
eq real-tag-annotated "tag/tag" "$(git -C "$W" cat-file -t v0.1.3)/$(git -C "$E/origin.git" cat-file -t v0.1.3)"
eq real-main-pushed "$(git -C "$W" rev-parse main)" "$(git -C "$E/origin.git" rev-parse main)"
eq real-gh "gh release create v0.1.3 --generate-notes" "$(grep '^gh ' "$STUBLOG")"
eq real-curl-url "curl -fsSL -o $(grep -o '[^ ]*src.tar.gz' "$STUBLOG") https://github.com/iamdin/agyx/archive/refs/tags/v0.1.3.tar.gz" "$(grep '^curl ' "$STUBLOG")"
eq real-brew "brew update|brew audit --strict --online iamdin/tap/agyx" "$(grep '^brew ' "$STUBLOG" | tr '\n' '|' | sed 's/|$//')"
eq real-tap-commit "agyx 0.1.3" "$(git -C "$E/tap-origin.git" log -1 --format=%s main)"
eq real-tap-formula-sha "1,0" "$(git -C "$E/tap-origin.git" show main:Formula/agyx.rb | grep -c "sha256 \"$SHA\""),$(git -C "$E/tap-origin.git" show main:Formula/agyx.rb | grep -c 'PLACEHOLDER\|0000000000')"
eq real-template-untouched "1" "$(grep -c '0000000000' "$W/Formula/agyx.rb")"
eq real-clean "" "$(git -C "$W" status --porcelain)"
# a failed audit is reported with a failing exit status after the release is done
mk; printf 'y\n' > "$E/ans"; printf '#!/bin/sh\necho "brew $*" >> "$STUBLOG"\n[ "$1" = audit ] && exit 1\nexit 0\n' > "$T/stubs/brew"
(cd "$W" && AGYX_TTY=$E/ans sh scripts/release.sh 0.1.3 >"$T/out" 2>&1 </dev/null); rc=$?
eq real-audit-fails "1,released" "$rc,$(git -C "$E/origin.git" tag -l v0.1.3 | sed 's/.*/released/')"
printf '#!/bin/sh\necho "brew $*" >> "$STUBLOG"\n' > "$T/stubs/brew"
# the tap path can come from AGYX_TAP_DIR
mk; mv "$E/homebrew-tap" "$E/mytap"; rel --dry-run 0.1.3; eq dry-run-default-tap-missing "1" "$?"
(cd "$W" && AGYX_TAP_DIR=$E/mytap sh scripts/release.sh --dry-run 0.1.3 >"$T/out" 2>&1 </dev/null); eq dry-run-tap-env "0" "$?"

echo "passed: $pass, failed: $fail"
[ "$fail" = 0 ]
