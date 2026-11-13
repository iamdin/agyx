#!/bin/sh
# Release agyx from the maintainer's machine: scripts/release.sh [--dry-run] VERSION
# Runs every check first and refuses unless all pass; prints each step before doing it.
# --dry-run runs the checks (including tests and shellcheck) and prints the commands without
# running them. Never installs agyx. See RELEASING.md.
set -eu

usage() { echo "usage: scripts/release.sh [--dry-run] VERSION   (for example 0.1.3)" >&2; exit 2; }

dry=0 version=
for a in "$@"; do
  case $a in
    --dry-run) dry=1 ;;
    -*) usage ;;
    *) [ -z "$version" ] || usage; version=$a ;;
  esac
done
case $version in
  [0-9]*.[0-9]*.[0-9]*) case $version in *[!0-9.]*|*..*) usage ;; esac ;;
  *) usage ;;
esac

root=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$root"
tag=v$version
tap=${AGYX_TAP_DIR:-$root/../homebrew-tap}
formula=Formula/agyx.rb
bad=0

step() { printf '\n== %s\n' "$*"; }
ok() { printf '  ok   %s\n' "$*"; }
no() { printf '  FAIL %s\n' "$*"; bad=1; }
run() { # print the command; run it unless --dry-run
  printf '  + %s\n' "$*"
  [ "$dry" = 1 ] && return 0
  "$@"
}
push() { # push over the remote's own URL, then over HTTPS when that fails (for example no SSH key)
  _d=$1; shift
  printf '  + git -C %s push origin %s\n' "$_d" "$*"
  [ "$dry" = 1 ] && return 0
  git -C "$_d" push origin "$@" && return 0
  echo "  push failed; retrying over HTTPS"
  git -C "$_d" -c "url.https://github.com/.insteadOf=git@github.com:" push origin "$@"
}

[ "$dry" = 1 ] && echo "DRY RUN: checks run for real, nothing is changed afterwards."

step "1. repository state"
branch=$(git symbolic-ref -q --short HEAD || true)
[ "$branch" = main ] && ok "on main" || no "not on main (on ${branch:-a detached HEAD})"
[ -z "$(git status --porcelain)" ] && ok "working tree clean" || no "working tree not clean"
if git fetch -q --tags origin 2>/dev/null; then
  if [ "$(git rev-parse main 2>/dev/null)" = "$(git rev-parse origin/main 2>/dev/null)" ]; then ok "main equals origin/main"
  else no "main differs from origin/main (push or pull first)"; fi
else no "git fetch origin failed"; fi
src=$(sed -n 's/^AGYX_VERSION=\([0-9][0-9.]*\).*/\1/p' runtime/sync.sh)
[ "$src" = "$version" ] && ok "AGYX_VERSION is $version" || no "AGYX_VERSION in runtime/sync.sh is '$src', not $version"
furl=$(sed -n 's|^ *url ".*/tags/v\([0-9][0-9.]*\)\.tar\.gz".*|\1|p' "$formula")
[ "$furl" = "$version" ] && ok "formula url tag is $tag" || no "formula url tag in $formula is '$furl', not $tag"
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then no "tag $tag already exists"; else ok "tag $tag does not exist yet"; fi
if git -C "$tap" rev-parse --git-dir >/dev/null 2>&1; then
  if [ -z "$(git -C "$tap" status --porcelain)" ]; then ok "tap checkout $tap is clean"; else no "tap checkout $tap is not clean"; fi
else no "tap checkout not found at $tap (set AGYX_TAP_DIR)"; fi

step "2. tests and shellcheck"
if sh test/run.sh </dev/null >/dev/null 2>&1; then ok "sh test/run.sh"; else no "sh test/run.sh fails (run it to see why)"; fi
if shellcheck -s sh -S warning bin/agy bin/agyx runtime/sync.sh runtime/bash_env runtime/zsh/.zshenv test/run.sh test/release.sh scripts/release.sh; then ok "shellcheck"
else no "shellcheck"; fi

step "3. commit emails since the previous tag"
email=$(git config user.email || true)
prev=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)
range=${prev:+$prev..}HEAD
if [ -z "$email" ]; then no "git config user.email is not set"
else
  others=$(git log --format='%h %ae %ce' "$range" | awk -v e="$email" '$2 != e || $3 != e')
  if [ -z "$others" ]; then ok "all commits in ${range} use $email"
  else no "commits not using $email (hash author committer):"; echo "$others" | sed 's/^/         /'; fi
fi

[ "$bad" = 0 ] || { echo; echo "Refusing to release $version: fix the failed checks above." >&2; exit 1; }

step "4. confirmation"
if [ "$dry" = 1 ]; then echo "  (dry run: would ask 'Release $version? [y/N]')"
else
  printf '  Release %s? [y/N] ' "$version"
  ans=
  read -r ans < "${AGYX_TTY:-/dev/tty}" || ans=
  case $ans in [Yy]|[Yy][Ee][Ss]) ;; *) echo "Cancelled; nothing was changed." >&2; exit 1 ;; esac
fi

step "5. tag and push"
run git tag -a "$tag" -m "agyx $version"
push "$root" main "$tag"

step "6. GitHub release"
run gh release create "$tag" --generate-notes

step "7. Homebrew tap"
turl=$(sed -n 's|^ *url "\(.*\)".*|\1|p' "$formula")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
if [ "$dry" = 1 ]; then
  echo "  + curl -fsSL -o <tarball> $turl"
  sha='<sha256 of the tag tarball>'
else
  printf '  + curl -fsSL -o %s/src.tar.gz %s\n' "$tmp" "$turl"
  curl -fsSL -o "$tmp/src.tar.gz" "$turl"
  sha=$(shasum -a 256 "$tmp/src.tar.gz" | cut -d' ' -f1)
  case $sha in [0-9a-f]*) [ ${#sha} = 64 ] || { echo "bad sha256: $sha" >&2; exit 1; } ;; *) echo "bad sha256: $sha" >&2; exit 1 ;; esac
fi
echo "  sha256 $sha"
run git -C "$tap" pull -q --ff-only
echo "  + write $formula into $tap with the real sha256"
if [ "$dry" = 0 ]; then
  mkdir -p "$tap/Formula"
  sed -e '/^ *# PLACEHOLDER/d' -e "s/^\( *sha256 \)\"[0-9a-f]*\"/\1\"$sha\"/" "$formula" > "$tap/Formula/agyx.rb"
fi
run git -C "$tap" add Formula/agyx.rb
run git -C "$tap" commit -q -m "agyx $version"
push "$tap"

step "8. brew audit"
if [ "$dry" = 1 ]; then
  echo "  + brew update && brew audit --strict --online iamdin/tap/agyx"
else
  brew update || true
  if brew audit --strict --online iamdin/tap/agyx; then echo "  brew audit: clean"
  else echo "  brew audit reported problems (the release itself is done); see above" >&2; exit 1; fi
fi
echo; echo "Done: $tag"
