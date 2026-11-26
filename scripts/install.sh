#!/bin/sh
# Install agyx: curl -fsSL https://raw.githubusercontent.com/iamdin/agyx/main/scripts/install.sh | sh
# Downloads the bootstrap ref (DEFAULT_REF / AGYX_REF) or AGYX_VERSION tag, installs bin/ +
# runtime/ under ~/.local/lib/agyx, and links ~/.local/bin/agyx. Never touches profile data
# (~/.local/share/agyx). Local checkout: sh scripts/install.sh
set -eu

REPO=iamdin/agyx
# Bootstrap channel when AGYX_VERSION is unset.
DEFAULT_REF=main
PREFIX=${AGYX_PREFIX:-${HOME:?}/.local/lib/agyx}
BINDIR=${AGYX_BINDIR:-$HOME/.local/bin}
VERSION=${AGYX_VERSION-}
REF=${AGYX_REF-}
FROM=${AGYX_INSTALL_FROM-}

usage() {
  echo "usage: install.sh [--prefix DIR] [--bin-dir DIR] [--version VER] [--from DIR]" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case $1 in
    --prefix) [ $# -ge 2 ] || usage; PREFIX=$2; shift 2 ;;
    --prefix=*) PREFIX=${1#--prefix=}; shift ;;
    --bin-dir) [ $# -ge 2 ] || usage; BINDIR=$2; shift 2 ;;
    --bin-dir=*) BINDIR=${1#--bin-dir=}; shift ;;
    --version) [ $# -ge 2 ] || usage; VERSION=$2; shift 2 ;;
    --version=*) VERSION=${1#--version=}; shift ;;
    --from) [ $# -ge 2 ] || usage; FROM=$2; shift 2 ;;
    --from=*) FROM=${1#--from=}; shift ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

die() { echo "agyx install: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required"; }

need tar
if command -v curl >/dev/null 2>&1; then
  fetch() { curl -fsSL "$1"; }
  fetch_file() { curl -fsSL -o "$2" "$1"; }
elif command -v wget >/dev/null 2>&1; then
  fetch() { wget -q -O - "$1"; }
  fetch_file() { wget -q -O "$2" "$1"; }
else
  die "curl or wget is required"
fi

# Resolve the script's own directory when not piped through sh (checkout / extracted tree).
self=$0
case $self in
  /*) ;;
  *) self=$(pwd -P)/$self ;;
esac
self_dir=
case $self in
  */*)
    _d=${self%/*}
    if [ -x "$_d/../bin/agyx" ] && [ -f "$_d/../runtime/sync.sh" ]; then
      self_dir=$(cd "$_d/.." && pwd -P) || true
    fi
    ;;
esac

resolve_from() {
  if [ -n "$FROM" ]; then
    [ -x "$FROM/bin/agyx" ] && [ -f "$FROM/runtime/sync.sh" ] || die "--from DIR needs bin/agyx and runtime/sync.sh: $FROM"
    FROM=$(cd "$FROM" && pwd -P) || die "cannot resolve --from: $FROM"
    if [ -z "$VERSION" ] && [ -f "$FROM/runtime/sync.sh" ]; then
      VERSION=$(sed -n 's/^AGYX_VERSION=\([^ #]*\).*/\1/p' "$FROM/runtime/sync.sh" | head -n 1)
    fi
    return 0
  fi
  if [ -n "$self_dir" ] && [ -z "$VERSION" ]; then
    FROM=$self_dir
    VERSION=$(sed -n 's/^AGYX_VERSION=\([^ #]*\).*/\1/p' "$FROM/runtime/sync.sh" | head -n 1)
    return 0
  fi
  return 1
}

download_archive() {
  need mktemp
  url=$1
  label=$2
  echo "agyx install: downloading $label..."
  tmp=$(mktemp -d) || die "mktemp failed"
  # shellcheck disable=SC2064 # expand now so the path is fixed for EXIT
  trap 'rm -rf "$tmp"' EXIT
  fetch_file "$url" "$tmp/src.tar.gz" || die "download failed: $url"
  tar -xzf "$tmp/src.tar.gz" -C "$tmp" || die "cannot extract tarball"
  FROM=
  for d in "$tmp"/*/; do
    if [ -x "${d}bin/agyx" ] && [ -f "${d}runtime/sync.sh" ]; then
      FROM=${d%/}
      break
    fi
  done
  [ -n "$FROM" ] || die "tarball has no bin/agyx + runtime/sync.sh"
  if [ -z "$VERSION" ]; then
    VERSION=$(sed -n 's/^AGYX_VERSION=\([^ #]*\).*/\1/p' "$FROM/runtime/sync.sh" | head -n 1)
  fi
}

download_release() {
  if [ -n "$VERSION" ]; then
    tag=v${VERSION#v}
    VERSION=${tag#v}
    download_archive "https://github.com/$REPO/archive/refs/tags/$tag.tar.gz" "$tag"
    return 0
  fi
  ref=${REF:-$DEFAULT_REF}
  case $ref in
    v[0-9]*) download_archive "https://github.com/$REPO/archive/refs/tags/$ref.tar.gz" "$ref" ;;
    *) download_archive "https://github.com/$REPO/archive/refs/heads/$ref.tar.gz" "$ref" ;;
  esac
}

if ! resolve_from; then
  download_release
fi
[ -n "$VERSION" ] || VERSION=unknown

echo "agyx install: $VERSION -> $PREFIX"
stage=$PREFIX.new.$$
rm -rf "$stage"
mkdir -p "$stage/bin" "$stage/runtime" || die "cannot create $stage"
# Copy only what the runtime needs to stay co-located (same layout as the Homebrew formula).
for f in agy agyx; do
  cp "$FROM/bin/$f" "$stage/bin/$f" || die "missing $FROM/bin/$f"
  chmod 755 "$stage/bin/$f"
done
# runtime/: shared sh library
cp "$FROM/runtime/sync.sh" "$stage/runtime/" || die "missing runtime/sync.sh"
printf '%s\n' "$VERSION" > "$stage/.agyx-prefix"
# Replace any previous prefix install atomically from the caller's point of view.
mkdir -p "${PREFIX%/*}" "$BINDIR" || die "cannot create install directories"
rm -rf "$PREFIX"
mv "$stage" "$PREFIX" || die "cannot move install into $PREFIX"
ln -sfn "$PREFIX/bin/agyx" "$BINDIR/agyx" || die "cannot link $BINDIR/agyx"

echo "agyx install: linked $BINDIR/agyx -> $PREFIX/bin/agyx"
case :$PATH: in
  *:$BINDIR:*) ;;
  *)
    echo "agyx install: note: $BINDIR is not on PATH; add it (agyx never edits shell startup files):"
    echo "  export PATH=\"$BINDIR:\$PATH\""
    ;;
esac
echo "agyx install: done. Next: agyx profile login NAME"
trap - EXIT
rm -rf "${tmp-}"
