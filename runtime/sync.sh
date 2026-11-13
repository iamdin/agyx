# shellcheck shell=sh
# shellcheck disable=SC2154 # R, P and data are set by the sourcing script
# Sourced by bin/agy (sync on every launch) and bin/agyx (doctor, setup).
# R = real home, P = profile home, data = agyx data dir; all set by the caller.
# The sync functions use only shell builtins when everything is already correct (no forks);
# they never write to stdout (warnings go to stderr).

AGYX_DEFAULT_LINKS=".gitconfig .ssh .config .npm .npmrc .bun .bunfig.toml .cache .cargo .rustup go Code GitHub"

# Entries of <gemini>/antigravity-cli that stay real files/dirs in the profile.
agyx_private() { # rel-dir name
  case $1/$2 in
    .gemini/antigravity-cli/antigravity-oauth-token|.gemini/antigravity-cli/log|.gemini/antigravity-cli/cli.log|.gemini/antigravity-cli/jetbox_summaries_proto.pb) return 0 ;;
  esac
  return 1
}

# Move $1 into P/agyx-drift/<rel>.<timestamp> (rel = $2).
agyx_drift_away() {
  _dst=$P/agyx-drift/$2.$(date +%Y%m%d%H%M%S)
  (umask 077; mkdir -p "${_dst%/*}") && mv "$1" "$_dst"
}

# One shared entry: $1 = shared path (in R), $2 = profile path (in P), $3 = relative name.
agyx_link_entry() {
  if [ -L "$2" ]; then
    [ "$2" -ef "$1" ] && return 0
    rm -f "$2" && ln -s "$1" "$2"
  elif [ ! -e "$2" ]; then
    ln -s "$1" "$2"
  elif [ -d "$2" ]; then
    echo "agyx: warning: $2 is a real directory but $1 is shared; not merged" >&2
  elif [ ! -f "$2" ]; then
    echo "agyx: warning: $2 is not a regular file or directory; left untouched" >&2
  elif [ ! -f "$1" ]; then
    agyx_drift_away "$2" "$3" && ln -s "$1" "$2"
    echo "agyx: warning: $2 was a file where a shared directory exists; moved to $P/agyx-drift" >&2
  elif cmp -s "$2" "$1"; then
    rm -f "$2" && ln -s "$1" "$2"
  elif [ "$2" -nt "$1" ]; then
    agyx_drift_away "$1" "$3" && mv "$2" "$1" && ln -s "$1" "$2"
    echo "agyx: warning: $2 was newer than the shared copy; shared copy kept in $P/agyx-drift, profile copy is now shared" >&2
  else
    agyx_drift_away "$2" "$3" && ln -s "$1" "$2"
    echo "agyx: warning: $2 differed from the shared copy; kept in $P/agyx-drift" >&2
  fi
}

# Sync one level: $1 = rel dir (".gemini" or ".gemini/antigravity-cli").
agyx_sync_dir() {
  _rd=$R/$1 _pd=$P/$1
  [ -d "$_rd" ] || (umask 077; mkdir -p "$_rd")
  [ -d "$_pd" ] || (umask 077; mkdir -p "$_pd")
  for _f in "$_rd"/* "$_rd"/.[!.]* "$_rd"/..?*; do
    [ -e "$_f" ] || [ -L "$_f" ] || continue
    _n=${_f##*/}
    [ "$_n" = antigravity-cli ] && [ "$1" = .gemini ] && continue
    agyx_private "$1" "$_n" && continue
    agyx_link_entry "$_f" "$_pd/$_n" "$1/$_n"
  done
  # adopt profile-only entries
  for _f in "$_pd"/* "$_pd"/.[!.]* "$_pd"/..?*; do
    [ -e "$_f" ] || [ -L "$_f" ] || continue
    [ -L "$_f" ] && continue
    _n=${_f##*/}
    [ "$_n" = antigravity-cli ] && [ "$1" = .gemini ] && continue
    agyx_private "$1" "$_n" && continue
    [ -e "$_rd/$_n" ] || [ -L "$_rd/$_n" ] && continue
    mv "$_f" "$_rd/$_n" && ln -s "$_rd/$_n" "$_f"
  done
}

agyx_sync_gemini() {
  agyx_sync_dir .gemini
  agyx_sync_dir .gemini/antigravity-cli
}

# Names that may be linked: a single path component, not handled elsewhere.
agyx_valid_link() {
  case $1 in
    ''|.|..|*/*|.gemini|Library|.local) return 1 ;;
  esac
  return 0
}

# Call "$1 name" for each whitelist name (file <data>/home-links, else the built-in default).
# Comments, blanks and surrounding whitespace are ignored; invalid names are passed on as-is
# to the callback, which decides what to do (skip with a warning, report, ...).
agyx_each_link() {
  if [ -f "$data/home-links" ]; then
    while IFS= read -r _l || [ -n "$_l" ]; do
      _l=${_l#"${_l%%[![:space:]]*}"}
      _l=${_l%"${_l##*[![:space:]]}"}
      case $_l in ''|'#'*) continue ;; esac
      "$1" "$_l"
    done < "$data/home-links"
  else
    for _l in $AGYX_DEFAULT_LINKS; do "$1" "$_l"; done
  fi
}

agyx_link_one() {
  if ! agyx_valid_link "$1"; then
    echo "agyx: warning: home-links: skipping invalid name '$1'" >&2
    return 0
  fi
  if [ -L "$P/$1" ]; then
    if [ -e "$P/$1" ]; then return 0; fi # live link (to R/<name> or elsewhere): nothing to do
    # dangling: remove it only if it pointed at the real home entry that is now gone
    [ -e "$R/$1" ] || [ "$(readlink "$P/$1")" != "$R/$1" ] || rm -f "$P/$1"
  elif [ ! -e "$P/$1" ] && [ -e "$R/$1" ]; then
    ln -s "$R/$1" "$P/$1"
  fi
  return 0
}

agyx_sync_home() { agyx_each_link agyx_link_one; }

# ---- doctor helpers (forks are fine here) ----

agyx_report_link() {
  agyx_valid_link "$1" || { echo "  home-links $1: invalid name (skipped)"; return 0; }
  if [ -L "$P/$1" ] && [ "$P/$1" -ef "$R/$1" ] && [ -e "$R/$1" ]; then echo "  home-links $1: linked"
  elif [ ! -e "$R/$1" ] && [ ! -L "$P/$1" ]; then echo "  home-links $1: missing in the real home"
  elif [ ! -e "$P/$1" ] && [ ! -L "$P/$1" ]; then echo "  home-links $1: not linked yet (linked on next launch)"
  elif [ -L "$P/$1" ] && [ ! -e "$P/$1" ] && [ ! -e "$R/$1" ] && [ "$(readlink "$P/$1")" = "$R/$1" ]; then echo "  home-links $1: dangling link (removed on next launch)"
  else echo "  home-links $1: CONFLICT (not a link to $R/$1; left untouched)"; fi
}

agyx_report_dir() { # rel dir
  _rd=$R/$1 _pd=$P/$1
  for _f in "$_rd"/* "$_rd"/.[!.]* "$_rd"/..?*; do
    [ -e "$_f" ] || [ -L "$_f" ] || continue
    _n=${_f##*/}
    [ "$_n" = antigravity-cli ] && [ "$1" = .gemini ] && continue
    agyx_private "$1" "$_n" && continue
    if [ -L "$_pd/$_n" ] && [ "$_pd/$_n" -ef "$_f" ]; then continue
    elif [ -d "$_pd/$_n" ] && [ ! -L "$_pd/$_n" ]; then echo "  shared $1/$_n: real directory in the profile (not merged)"
    elif [ -f "$_pd/$_n" ] && [ ! -L "$_pd/$_n" ]; then echo "  shared $1/$_n: drift (regular file in the profile)"
    else echo "  shared $1/$_n: not linked (fixed on next launch)"; fi
  done
}

agyx_report() {
  agyx_report_dir .gemini
  agyx_report_dir .gemini/antigravity-cli
  if [ -d "$P/agyx-drift" ]; then echo "  agyx-drift: $(find "$P/agyx-drift" -type f | wc -l | tr -d ' ') file(s)"
  else echo "  agyx-drift: 0 file(s)"; fi
  agyx_each_link agyx_report_link
}
