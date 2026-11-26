#!/bin/sh
# Release agyx from the maintainer's machine: scripts/release.sh [--dry-run] [--beta] VERSION
# Runs the checks first and refuses unless all pass; prints each step before doing it.
# --dry-run runs the checks (including tests and shellcheck) and prints the commands without
# running them. Never installs agyx. See RELEASING.md.
set -eu

usage() { echo "usage: scripts/release.sh [--dry-run] [--beta] VERSION   (for example 0.2.2 or 0.2.2-beta.1)" >&2; exit 2; }

dry=0 beta_flag=0 version=
for a in "$@"; do
  case $a in
    --dry-run) dry=1 ;;
    --beta) beta_flag=1 ;;
    -*) usage ;;
    *) [ -z "$version" ] || usage; version=$a ;;
  esac
done
beta=0
case $version in
  *-beta.*)
    beta=1
    base=${version%-beta.*}
    bnum=${version#*-beta.}
    case $bnum in
      [1-9]*) case $bnum in *[!0-9]*) usage ;; esac ;;
      *) usage ;;
    esac
    ;;
  *)
    [ "$beta_flag" = 0 ] || usage
    base=$version
    ;;
esac
case $base in
  [0-9]*.[0-9]*.[0-9]*) case $base in *[!0-9.]*|*..*|*.*.*.*|*.) usage ;; esac ;;
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
pull() { # pull over the remote's own URL, then over HTTPS when that fails
  _d=$1; shift
  printf '  + git -C %s pull %s\n' "$_d" "$*"
  [ "$dry" = 1 ] && return 0
  git -C "$_d" pull "$@" && return 0
  echo "  pull failed; retrying over HTTPS"
  git -C "$_d" -c "url.https://github.com/.insteadOf=git@github.com:" pull "$@"
}

[ "$dry" = 1 ] && echo "DRY RUN: checks run for real, nothing is changed afterwards."

step "1. what the release mechanics need"
branch=$(git symbolic-ref -q --short HEAD || true)
if [ "$beta" = 1 ]; then
  [ -n "$branch" ] && ok "on branch $branch (beta release)" || no "not on a branch (detached HEAD)"
else
  [ "$branch" = main ] && ok "on main (it is what gets tagged and pushed)" || no "not on main (on ${branch:-a detached HEAD})"
fi
git fetch -q --tags origin 2>/dev/null \
  || git -c "url.https://github.com/.insteadOf=git@github.com:" fetch -q --tags origin 2>/dev/null \
  || echo "  warn git fetch origin failed; remote tags were not checked"
src=$(sed -n 's/^AGYX_VERSION=\([^ #]*\).*/\1/p' runtime/sync.sh | head -n 1)
[ "$src" = "$version" ] && ok "AGYX_VERSION is $version" || no "AGYX_VERSION in runtime/sync.sh is '$src', not $version"
furl=$(sed -n 's|^ *url ".*/tags/v\([0-9][0-9.]*\)\.tar\.gz".*|\1|p' "$formula" 2>/dev/null || true)
if [ "$beta" = 1 ]; then
  [ -n "$furl" ] && ok "formula template found at $formula" || no "formula template url not found in $formula"
else
  [ "$furl" = "$version" ] && ok "formula url tag is $tag" || no "formula url tag in $formula is '$furl', not $tag"
fi
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then no "tag $tag already exists"; else ok "tag $tag does not exist yet"; fi
if git -C "$tap" rev-parse --git-dir >/dev/null 2>&1; then ok "tap checkout found at $tap"
else no "tap checkout not found at $tap (set AGYX_TAP_DIR)"; fi

step "2. tests and shellcheck"
if (unset AGYX_TAP_DIR AGYX_TTY; sh test/run.sh </dev/null >/dev/null 2>&1); then ok "sh test/run.sh"; else no "sh test/run.sh fails (run it to see why)"; fi
if shellcheck -s sh -S warning bin/agy bin/agyx runtime/sync.sh test/run.sh test/release.sh scripts/release.sh scripts/install.sh; then ok "shellcheck"
else no "shellcheck"; fi

[ "$bad" = 0 ] || { echo; echo "Refusing to release $version: fix the failed checks above." >&2; exit 1; }

step "3. confirmation"
if [ "$dry" = 1 ]; then echo "  (dry run: would ask 'Release $version? [y/N]')"
else
  printf '  Release %s? [y/N] ' "$version"
  ans=
  read -r ans < "${AGYX_TTY:-/dev/tty}" || ans=
  case $ans in [Yy]|[Yy][Ee][Ss]) ;; *) echo "Cancelled; nothing was changed." >&2; exit 1 ;; esac
fi

step "4. tag and push"
run git tag -a "$tag" -m "agyx $version"
push "$root" "$branch" "$tag"

step "5. GitHub release"
if [ "$beta" = 1 ]; then
  run gh release create "$tag" --prerelease --generate-notes
else
  run gh release create "$tag" --generate-notes
fi

step "6. Homebrew tap"
if [ "$beta" = 1 ]; then
  turl=$(sed -n "s|^ *url \"\\(.*\\)/tags/v[^\"]*\\.tar\\.gz\".*|\\1/tags/$tag.tar.gz|p" "$formula")
  tap_formula=Formula/agyx-beta.rb
  tap_name=agyx-beta
else
  turl=$(sed -n 's|^ *url "\(.*\)".*|\1|p' "$formula")
  tap_formula=$formula
  tap_name=agyx
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
if [ "$dry" = 1 ]; then
  echo "  + curl -fsSL -o <tarball> $turl"
  sha='<sha256 of the tag tarball>'
else
  printf '  + curl -fsSL -o %s/src.tar.gz %s\n' "$tmp" "$turl"
  curl -fsSL -o "$tmp/src.tar.gz" "$turl"
  if command -v shasum >/dev/null 2>&1; then sha=$(shasum -a 256 "$tmp/src.tar.gz" | cut -d' ' -f1)
  else sha=$(sha256sum "$tmp/src.tar.gz" | cut -d' ' -f1)
  fi
  case $sha in [0-9a-f]*) [ ${#sha} = 64 ] || { echo "bad sha256: $sha" >&2; exit 1; } ;; *) echo "bad sha256: $sha" >&2; exit 1 ;; esac
fi
echo "  sha256 $sha"
pull "$tap" -q --ff-only
echo "  + write $tap_formula into $tap with the real sha256"
if [ "$dry" = 0 ]; then
  mkdir -p "$tap/Formula"
  if [ "$beta" = 1 ]; then
    sed \
      -e 's|^# This file is published in .* (Formula/agyx\.rb)\.$|# Beta formula in the tap repository iamdin/homebrew-tap (Formula/agyx-beta.rb).|' \
      -e 's|^class Agyx < Formula$|class AgyxBeta < Formula|' \
      -e "s|^\\( *url \"\\)[^\"]*\"|\\1$turl\"|" \
      -e '/^ *# PLACEHOLDER/d' \
      -e "s/^\\( *sha256 \\)\"[0-9a-f]*\"/\\1\"$sha\"/" \
      -e 's|^\( *conflicts_with \)"agyx-beta"|\1"agyx"|' \
      "$formula" > "$tmp/agyx-beta.rb"
    if grep -q '^ *conflicts_with ' "$tmp/agyx-beta.rb"; then
      cp "$tmp/agyx-beta.rb" "$tap/$tap_formula"
    else
      awk '/^ *sha256 / { print; print "  conflicts_with \"agyx\", because: \"both install agyx\""; next } { print }' \
        "$tmp/agyx-beta.rb" > "$tap/$tap_formula"
    fi
  else
    sed -e '/^ *# PLACEHOLDER/d' -e "s/^\( *sha256 \)\"[0-9a-f]*\"/\1\"$sha\"/" "$formula" > "$tap/$tap_formula"
  fi
fi
run git -C "$tap" add "$tap_formula"
run git -C "$tap" commit -q -m "$tap_name $version"
push "$tap"

step "7. brew audit"
if [ "$dry" = 1 ]; then
  echo "  + brew update && brew audit --strict --online iamdin/tap/$tap_name"
else
  brew update || true
  if brew audit --strict --online "iamdin/tap/$tap_name"; then echo "  brew audit: clean"
  else echo "  brew audit reported problems (the release itself is done); see above" >&2; exit 1; fi
fi
echo; echo "Done: $tag"
