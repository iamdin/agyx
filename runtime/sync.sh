# shellcheck shell=sh
# shellcheck disable=SC2154 # R, P and data are set by the sourcing script
# Sourced by bin/agy (sync on every launch) and bin/agyx (doctor, setup).
# R = real home, P = profile home, data = agyx data dir; all set by the caller.
# The sync functions use only shell builtins when everything is already correct (no forks);
# they never write to stdout (warnings go to stderr).

AGYX_DEFAULT_LINKS=".gitconfig .ssh .config .npm .npmrc .bun .bunfig.toml .cache .cargo .rustup go Code GitHub"

# Entries that are never synced: the per-profile private set and SQLite sidecar files.
agyx_private() { # rel-dir name
  case $2 in # SQLite sidecars sit next to the real database (opened through the link); never sync them
    *-wal|*-shm|*-journal) return 0 ;;
  esac
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
    if [ -d "$1" ] && diff -rq "$1" "$2" >/dev/null 2>&1; then
      # identical content (e.g. a cache): keep a copy in agyx-drift, then share it
      agyx_drift_away "$2" "$3" && ln -s "$1" "$2"
    else
      echo "agyx: warning: $2 is a real directory but $1 is shared; not merged" >&2
    fi
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

# Whitelist file: ${XDG_CONFIG_HOME:-$R/.config}/agyx/symlinks. XDG_CONFIG_HOME counts only when it is an
# absolute path; the default is resolved from the real home R, never from a profile home.
agyx_set_links_file() {
  case ${XDG_CONFIG_HOME-} in
    /*) AGYX_LINKS_FILE=$XDG_CONFIG_HOME/agyx/symlinks ;;
    *) AGYX_LINKS_FILE=$R/.config/agyx/symlinks ;;
  esac
}

# Call "$1 name" for each whitelist name (from that file, else the built-in default).
# Comments, blanks and surrounding whitespace are ignored; invalid names are passed on as-is
# to the callback, which decides what to do (skip with a warning, report, ...).
agyx_each_link() {
  agyx_set_links_file
  if [ -f "$AGYX_LINKS_FILE" ]; then
    while IFS= read -r _l || [ -n "$_l" ]; do
      _l=${_l#"${_l%%[![:space:]]*}"}
      _l=${_l%"${_l##*[![:space:]]}"}
      case $_l in ''|'#'*) continue ;; esac
      "$1" "$_l"
    done < "$AGYX_LINKS_FILE"
  else
    for _l in $AGYX_DEFAULT_LINKS; do "$1" "$_l"; done
  fi
}

agyx_link_one() {
  if ! agyx_valid_link "$1"; then
    echo "agyx: warning: symlinks: skipping invalid name '$1'" >&2
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
  agyx_valid_link "$1" || { echo "  symlinks $1: invalid name (skipped)"; return 0; }
  if [ -L "$P/$1" ] && [ "$P/$1" -ef "$R/$1" ] && [ -e "$R/$1" ]; then echo "  symlinks $1: linked"
  elif [ ! -e "$R/$1" ] && [ ! -L "$P/$1" ]; then echo "  symlinks $1: missing in the real home"
  elif [ ! -e "$P/$1" ] && [ ! -L "$P/$1" ]; then echo "  symlinks $1: not linked yet (linked on next launch)"
  elif [ -L "$P/$1" ] && [ ! -e "$P/$1" ] && [ ! -e "$R/$1" ] && [ "$(readlink "$P/$1")" = "$R/$1" ]; then echo "  symlinks $1: dangling link (removed on next launch)"
  else echo "  symlinks $1: CONFLICT (not a link to $R/$1; left untouched)"; fi
}

agyx_report_dir() { # rel dir
  _rd=$R/$1 _pd=$P/$1
  for _f in "$_rd"/* "$_rd"/.[!.]* "$_rd"/..?*; do
    [ -e "$_f" ] || [ -L "$_f" ] || continue
    _n=${_f##*/}
    [ "$_n" = antigravity-cli ] && [ "$1" = .gemini ] && continue
    agyx_private "$1" "$_n" && continue
    if [ -L "$_pd/$_n" ] && [ "$_pd/$_n" -ef "$_f" ]; then continue
    elif [ -d "$_pd/$_n" ] && [ ! -L "$_pd/$_n" ]; then
      if [ -d "$_f" ] && diff -rq "$_f" "$_pd/$_n" >/dev/null 2>&1; then echo "  shared $1/$_n: real directory, identical, replaced by a link on next launch"
      else echo "  shared $1/$_n: real directory in the profile (not merged)"; fi
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

# ---- automatic setup (there is no setup command) ----
# Callers define die(); R, data and AGYX_SHIM (the packaged bin/agy) must be set.

# Management subcommands of bin/agyx; they are also the reserved profile names (the only list).
agyx_subcommand() {
  case $1 in doctor|profile) return 0 ;; esac
  return 1
}

# Sets _found to the first executable `agy` on PATH that is not agyx's own entry point (absolute).
agyx_scan_path() {
  _found=
  _ifs=$IFS; IFS=:
  for _p in $PATH; do
    if [ -n "$_p" ] && [ -f "$_p/agy" ] && [ -x "$_p/agy" ] && [ ! "$_p/agy" -ef "$AGYX_SHIM" ]; then
      _found=$_p/agy; break
    fi
  done
  IFS=$_ifs
  [ -n "$_found" ] || return 1
  case $_found in /*) ;; *) _found=$PWD/$_found ;; esac
}

# Sets $real to the real agy. AGYX_REAL_AGY (absolute path) overrides everything and is not stored.
# Otherwise <data>/real-agy is used; when it is missing, not executable or points at the shim, the
# first executable `agy` on PATH that is not agyx's own entry point is found and stored there.
# Returns 1 when nothing usable exists. Steady state: builtins only, no forks.
agyx_find_real() {
  if [ -n "${AGYX_REAL_AGY-}" ]; then
    real=$AGYX_REAL_AGY
    [ -f "$real" ] && [ -x "$real" ] && [ ! "$real" -ef "$AGYX_SHIM" ]
    return
  fi
  real=$data/real-agy
  if [ -x "$real" ] && [ ! "$real" -ef "$AGYX_SHIM" ]; then return 0; fi
  agyx_scan_path || return 1
  real=$_found
  (umask 077; mkdir -p "$data") && ln -sfn "$real" "$data/real-agy" ||
    echo "agyx: warning: could not store $data/real-agy; the search will repeat on the next run" >&2
  return 0
}

# <data>/bin/agy: the path to give apps that need a binary named agy (it is the shim).
agyx_ensure_entry() {
  [ -e "$data/bin/agy" ] && return 0
  (umask 077; mkdir -p "$data/bin") && ln -sfn "$AGYX_SHIM" "$data/bin/agy" 2>/dev/null ||
    echo "agyx: warning: could not create $data/bin/agy" >&2
  return 0
}

# The whitelist file, written with the default list when missing (one stderr line, never stdout).
# If it cannot be written the built-in default list still applies.
agyx_ensure_links_file() {
  agyx_set_links_file
  [ -e "$AGYX_LINKS_FILE" ] && return 0
  if mkdir -p "${AGYX_LINKS_FILE%/*}" 2>/dev/null && {
    echo "# Names in your real home that agyx links into every profile home (one per line, # = comment)."
    echo "# Not allowed: ., .., names with a slash, .gemini, Library, .local."
    printf '%s\n' $AGYX_DEFAULT_LINKS
  } > "$AGYX_LINKS_FILE" 2>/dev/null; then
    echo "agyx: wrote $AGYX_LINKS_FILE (edit it to change what profiles share)" >&2
  fi
  return 0
}

# Nothing is written to the user's file system until the user agreed once. "Set up" = the data dir
# exists. Commands that write call this first. Without a terminal (stdin and stderr) it refuses;
# AGYX_ASSUME_YES=1 skips the question. AGYX_TTY=<file> is for tests only: it replaces the terminal
# check and /dev/tty as the place the answer is read from.
agyx_gate() {
  [ -d "$data" ] && return 0
  if [ "${AGYX_ASSUME_YES-}" != 1 ]; then
    if [ -z "${AGYX_TTY-}" ] && { [ ! -t 0 ] || [ ! -t 2 ]; }; then
      die "agyx is not set up yet. Run agyx once in a terminal to set it up (or set AGYX_ASSUME_YES=1)."
    fi
    if [ -n "${AGYX_REAL_AGY-}" ]; then _found=$AGYX_REAL_AGY
    elif ! agyx_scan_path; then _found="(not found yet: install agy, or set AGYX_REAL_AGY=/path/to/agy)"; fi
    agyx_set_links_file
    {
      echo "agyx will set up:"
      echo "  $data/  profiles (one HOME and keychain per account), a link to agy at $_found"
      echo "  $data/bin/agy  entry for apps that need a binary named agy"
      echo "  $AGYX_LINKS_FILE  home entries linked into every profile (editable)"
      echo "Profiles share your ~/.gemini settings and history; your login keychain is not touched."
      printf 'Continue? [Y/n] '
    } >&2
    _ans=
    read -r _ans < "${AGYX_TTY:-/dev/tty}" || [ -n "$_ans" ] || _ans=n
    case $_ans in ''|[Yy]*) ;; *) echo >&2; die "not set up; nothing was written." ;; esac
  fi
  (umask 077; mkdir -p "$data") || die "cannot create $data"
}
