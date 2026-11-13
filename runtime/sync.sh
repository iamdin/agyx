# shellcheck shell=sh
# shellcheck disable=SC2154,SC2034 # R, P and data are set by the sourcing script; AGYX_* are read by the callers
# Sourced by bin/agy (sync on every launch) and bin/agyx (doctor, setup).
# R = real home, P = profile home, data = agyx data dir; all set by the caller.
# The sync functions use only shell builtins when everything is already correct (no forks);
# they never write to stdout (warnings go to stderr).

AGYX_VERSION=0.1.2 # the one place the version lives (the formula's url tag must match)
AGYX_DEFAULT_LINKS=".gitconfig .ssh .config .npm .npmrc .bun .bunfig.toml .cache .cargo .rustup go Code GitHub"

# ---- the shared ~/.gemini ----
# <profile home>/.gemini is one symlink to the real ~/.gemini: everything agy keeps there is shared.
# The only private data of a profile is its keychain (home/Library/Keychains) and its "email" file.

# The token-file blocker. agy reads its login from the keychain and falls back to
# .gemini/antigravity-cli/antigravity-oauth-token, a file it writes when saving to the keychain fails.
# With a shared .gemini that file would be shared by every account, so agyx keeps a DIRECTORY at that
# path. This is an assumption about agy that is verified separately; it lives only in the next
# three functions.
agyx_blocker_state() { # sets AGYX_BLOCKER and AGYX_BLOCKER_STATE: ok | missing | blocking
  AGYX_BLOCKER=$R/.gemini/antigravity-cli/antigravity-oauth-token
  if [ -d "$AGYX_BLOCKER" ] && [ ! -L "$AGYX_BLOCKER" ]; then AGYX_BLOCKER_STATE=ok
  elif [ -e "$AGYX_BLOCKER" ] || [ -L "$AGYX_BLOCKER" ]; then AGYX_BLOCKER_STATE=blocking
  else AGYX_BLOCKER_STATE=missing; fi
}

agyx_make_blocker() {
  (umask 077; mkdir -p "$AGYX_BLOCKER") &&
    cat > "$AGYX_BLOCKER/README" 2>/dev/null <<'EOT'
agyx keeps this directory here so the Antigravity CLI (agy) cannot write a token file at this path:
all agyx profiles share this ~/.gemini, so such a file would be shared by every Google account.
Logins live only in each profile's own keychain. Delete this directory only after uninstalling agyx.
EOT
}

# Returns 0 when the blocker is in place (creating it when missing). When something that is not a
# directory sits at its path, prints what to do and returns 1; that file is never read, moved or deleted.
agyx_ensure_blocker() {
  agyx_blocker_state
  case $AGYX_BLOCKER_STATE in
    ok) return 0 ;;
    missing)
      agyx_make_blocker || echo "agyx: warning: could not create $AGYX_BLOCKER" >&2
      return 0 ;;
  esac
  # In a terminal a token file can be moved to the Trash on request (default No). It is never read.
  if { [ -f "$AGYX_BLOCKER" ] || [ -L "$AGYX_BLOCKER" ]; } && { [ -n "${AGYX_TTY-}" ] || { [ -t 0 ] && [ -t 2 ]; }; }; then
    {
      echo "agyx: found a login token file at $(agyx_tilde "$AGYX_BLOCKER")"
      echo "  It is probably plain agy's login. While it exists, every agyx profile could read it."
      printf '  Move it to the Trash? Plain agy will ask you to sign in again. [y/N] '
    } >&2
    _ans=
    read -r _ans < "${AGYX_TTY:-/dev/tty}" || [ -n "$_ans" ] || _ans=n
    case $_ans in
      [Yy]*)
        _td=${AGYX_TRASH_DIR:-$R/.Trash}/agyx-token-$(date +%Y%m%d%H%M%S)
        if (umask 077; mkdir -p "$_td") && mv "$AGYX_BLOCKER" "$_td/antigravity-oauth-token"; then
          echo "agyx: moved the token file to $(agyx_tilde "$_td")" >&2
          agyx_make_blocker || echo "agyx: warning: could not create $AGYX_BLOCKER" >&2
          return 0
        fi
        echo "agyx: warning: could not move the token file" >&2 ;;
      *) echo >&2 ;;
    esac
  fi
  {
    echo "agyx: not starting this profile: $(agyx_tilde "$AGYX_BLOCKER") exists and is not a directory."
    echo "It is probably a Google login token (for example the plain agy saved its login to a file)."
    echo "agyx shares ~/.gemini between all profiles, so every account could read that file."
    echo "Move it away yourself (agyx never reads, moves or deletes it), for example:"
    echo "  mv $(agyx_tilde "$AGYX_BLOCKER") ~/antigravity-oauth-token.saved"
    echo "If it is the plain agy's login, plain agy will ask you to sign in again."
  } >&2
  return 1
}

# Move $1 into the Trash folder of this migration, keeping the relative path $2.
agyx_trash() {
  _td=$AGYX_TRASH/$2
  (umask 077; mkdir -p "${_td%/*}") && mv "$1" "$_td" && _mtr=$((_mtr + 1))
}

# Merge the profile's real .gemini ($2) into the shared one ($1). Walk (parents first): missing on
# the shared side -> mv; two directories -> go deeper; identical files -> drop the profile copy;
# different files -> the newer one ends up in the shared tree and the other goes to the Trash; file
# against directory -> the profile entry goes to the Trash. Symlinks are moved as they are, never
# followed. Whatever is left afterwards goes to the Trash too. Names with a newline are not supported.
# Uses only _m* variables.
agyx_merge_dir() {
  _mv=0
  _mlist=$(find "$2" -mindepth 1 2>/dev/null)
  while IFS= read -r _mp; do
    [ -n "$_mp" ] || continue
    [ -e "$_mp" ] || [ -L "$_mp" ] || continue # moved or dropped together with its parent
    _mr=${_mp#"$2"/}
    _md=$1/$_mr
    if [ ! -e "$_md" ] && [ ! -L "$_md" ]; then
      mv "$_mp" "$_md" && _mv=$((_mv + 1))
    elif [ -L "$_mp" ]; then
      agyx_trash "$_mp" "$_mr"
    elif [ -d "$_mp" ]; then
      [ -d "$_md" ] || agyx_trash "$_mp" "$_mr"
    elif [ -f "$_mp" ]; then
      if [ -d "$_md" ] || [ -L "$_md" ]; then
        agyx_trash "$_mp" "$_mr"
      elif cmp -s "$_mp" "$_md"; then
        rm -f "$_mp"
      elif [ "$_mp" -nt "$_md" ]; then
        agyx_trash "$_md" "$_mr" && mv "$_mp" "$_md" && _mv=$((_mv + 1))
      else
        agyx_trash "$_mp" "$_mr"
      fi
    else
      agyx_trash "$_mp" "$_mr" # sockets, fifos, ...
    fi
  done <<EOT
$_mlist
EOT
  find "$2" -depth -mindepth 1 -type d -empty -exec rmdir {} + 2>/dev/null
  for _mp in "$2"/* "$2"/.[!.]* "$2"/..?*; do
    [ -e "$_mp" ] || [ -L "$_mp" ] || continue
    agyx_trash "$_mp" "${_mp##*/}"
  done
  rmdir "$2"
}

# Needs the keychain check from bin/agyx/bin/agy: agyx_kc_has_item NAME (see below).
# One-time migration of profile $1 from the per-entry layout (a real .gemini directory).
agyx_migrate_gemini() {
  _pn=$1 _g=$P/.gemini _gs=$R/.gemini
  AGYX_TRASH=${AGYX_TRASH_DIR:-$R/.Trash}/agyx-$_pn-$(date +%Y%m%d%H%M%S)
  _mtr=0 _mlk=0
  # 0. keep the account email (from the profile's own token file or log) before anything moves
  if [ ! -s "${P%/*}/email" ]; then
    _e=$(agyx_email_token "$_g/antigravity-cli/antigravity-oauth-token")
    [ -n "$_e" ] || _e=$(agyx_email_log "$_g/antigravity-cli/log")
    [ -z "$_e" ] || printf '%s\n' "$_e" > "${P%/*}/email"
  fi
  # 1. symlinks into the shared tree (the old per-entry links) are removed
  _ml=$(find "$_g" -type l 2>/dev/null)
  while IFS= read -r _lp; do
    [ -n "$_lp" ] || continue
    case $(readlink "$_lp") in "$_gs"/*) rm -f "$_lp" && _mlk=$((_mlk + 1)) ;; esac
  done <<EOT
$_ml
EOT
  # 2. logs and per-profile leftovers that have no value once shared, and SQLite sidecars
  for _x in log cli.log jetbox_summaries_proto.pb; do
    [ -e "$_g/antigravity-cli/$_x" ] || [ -L "$_g/antigravity-cli/$_x" ] && agyx_trash "$_g/antigravity-cli/$_x" "antigravity-cli/$_x"
  done
  _ml=$(find "$_g" ! -type d \( -name '*-wal' -o -name '*-shm' -o -name '*-journal' \) 2>/dev/null)
  while IFS= read -r _lp; do
    [ -n "$_lp" ] || continue
    agyx_trash "$_lp" "${_lp#"$_g"/}"
  done <<EOT
$_ml
EOT
  # 3. the profile's fallback login token file
  _tk=$_g/antigravity-cli/antigravity-oauth-token
  if [ -f "$_tk" ] || [ -L "$_tk" ]; then
    agyx_trash "$_tk" antigravity-cli/antigravity-oauth-token
    if agyx_kc_has_item "$_pn"; then
      echo "agyx: profile $_pn: its login token file was moved to the Trash ($(agyx_tilde "$AGYX_TRASH")). Its keychain holds a login, so nothing else is needed." >&2
    else
      echo "agyx: profile $_pn: its login token file was moved to the Trash ($(agyx_tilde "$AGYX_TRASH")), and its keychain holds no login: run 'agyx profile login $_pn' again if agy asks you to sign in." >&2
    fi
  fi
  # 4. everything else is merged into the shared tree, 5. the empty tree is removed
  agyx_merge_dir "$_gs" "$_g" || return 1
  # 6. one summary line
  echo "agyx: profile $_pn: its .gemini was merged into the shared $(agyx_tilde "$_gs"): $_mv entries moved, $_mlk old links removed, $_mtr items to the Trash$([ "$_mtr" -eq 0 ] || printf ' (%s)' "$(agyx_tilde "$AGYX_TRASH")")" >&2
}

# Make <profile home>/.gemini the single link to the shared tree. Steady state: one test, no forks.
agyx_sync_gemini() { # $1 = profile name
  if [ -L "$P/.gemini" ]; then
    [ "$P/.gemini" -ef "$R/.gemini" ] && return 0
    rm -f "$P/.gemini" && ln -s "$R/.gemini" "$P/.gemini"
  elif [ -d "$P/.gemini" ]; then
    agyx_migrate_gemini "$1" && ln -s "$R/.gemini" "$P/.gemini"
  elif [ -e "$P/.gemini" ]; then
    echo "agyx: warning: $P/.gemini is not a directory or a link; left untouched" >&2
  else
    ln -s "$R/.gemini" "$P/.gemini"
  fi
}

# Account email helpers (they print the email or nothing). Only id_token_email of the token file is
# ever read from it, never the access or refresh token.
agyx_email_token() { # file
  [ -f "$1" ] || return 0
  _et=$(plutil -extract id_token_email raw -o - "$1" 2>/dev/null | tr -d '[:cntrl:]')
  case $_et in ''|*[[:space:]]*) ;; *) printf '%s' "$_et" ;; esac
}
agyx_email_file() { # log file: last email= on an applyAuthResult line
  [ -f "$1" ] || return 0
  _el=$(grep applyAuthResult "$1" 2>/dev/null | sed -n 's/.*email=\([^][ ,;"}()]*\).*/\1/p' | tail -n 1 | tr -d '[:cntrl:]')
  case $_el in *[[:space:]]*) ;; *) printf '%s' "$_el" ;; esac
}
agyx_email_log() { # log dir: the same for its newest file
  _lf=$(ls -t "$1" 2>/dev/null | head -n 1)
  [ -n "$_lf" ] && agyx_email_file "$1/$_lf"
  return 0
}

# Does profile $1's keychain hold agy's login item? Never asks for the secret (no -w / -g).
agyx_kc_has_item() {
  _kc=$data/profiles/$1/home/Library/Keychains/login.keychain-db
  [ -e "$_kc" ] || return 1
  HOME=$data/profiles/$1/home "$sec" find-generic-password -s gemini -a antigravity "$_kc" >/dev/null 2>&1
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

agyx_report() {
  if [ -L "$P/.gemini" ] && [ "$P/.gemini" -ef "$R/.gemini" ]; then echo "  .gemini: linked to the shared $(agyx_tilde "$R/.gemini")"
  elif [ -d "$P/.gemini" ] && [ ! -L "$P/.gemini" ]; then echo "  .gemini: real directory, will be migrated into the shared one on next launch"
  elif [ ! -e "$P/.gemini" ] && [ ! -L "$P/.gemini" ]; then echo "  .gemini: not linked yet (linked on next launch)"
  else echo "  .gemini: not the link to the shared $(agyx_tilde "$R/.gemini") (fixed on next launch)"; fi
  agyx_each_link agyx_report_link
}

# ---- automatic setup (there is no setup command) ----
# Callers define die(); R, data and AGYX_SHIM (the packaged bin/agy) must be set.

# Management subcommands of bin/agyx; they are also the reserved profile names (the only list).
agyx_subcommand() {
  case $1 in doctor|profile|uninstall) return 0 ;; esac
  return 1
}

# Per-profile agy log: <profile dir>/log/cli-YYYYMMDD_HHMMSS.log, a new file per launch. agyx only
# says where agy writes (--log-file); it never reads, links or prunes these files.
# agy takes --log-file only BEFORE its subcommand (`agy --log-file F models` works, `agy models
# --log-file F` is rejected). The commands below never write a log, so no file is made for them; a
# log file the caller chose is left alone.
agyx_wants_log() {
  case ${1-} in help|changelog|mcp|update|--help|-h|--version) return 1 ;; esac
  for _a in "$@"; do case $_a in --log-file|--log-file=*) return 1 ;; esac; done
  return 0
}
# $1 = profile dir. Creates a new empty log file (never one that exists: a second launch in the
# same second gets _02, _03 ...) and sets AGYX_LOGFILE. Forks only for the date.
# AGYX_LOG_STAMP replaces the timestamp (tests).
agyx_new_log() {
  _ld=$1/log
  [ -d "$_ld" ] || (umask 077; mkdir -p "$_ld") || return 1
  _b=$_ld/cli-${AGYX_LOG_STAMP:-$(date +%Y%m%d_%H%M%S)}
  AGYX_LOGFILE=$_b.log; _i=1
  while ! (umask 077; set -C; : > "$AGYX_LOGFILE") 2>/dev/null; do
    _i=$((_i + 1)); [ "$_i" -lt 100 ] || return 1
    AGYX_LOGFILE=${_b}_$(printf %02d "$_i").log
  done
  return 0
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
  [ "$data/bin/agy" -ef "$AGYX_SHIM" ] && return 0
  if [ -L "$data/bin/agy" ]; then
    if [ -e "$data/bin/agy" ]; then
      _t=$(readlink "$data/bin/agy")
      case $_t in /*) ;; *) _t=$data/bin/$_t ;; esac
      [ "${_t##*/}" = agy ] && [ -f "${_t%/*}/../runtime/sync.sh" ] || return 0
    fi
  elif [ -e "$data/bin/agy" ]; then
    return 0
  fi
  (umask 077; mkdir -p "$data/bin") && ln -sfn "$AGYX_SHIM" "$data/bin/agy" 2>/dev/null ||
    echo "agyx: warning: could not create $data/bin/agy" >&2
  return 0
}

# Sets AGYX_STABLE to the path agyx stores or passes on for itself. Homebrew keeps each version in
# its own Cellar directory and deletes old ones, while <prefix>/opt/agyx is a stable link to the
# current version: <prefix>/Cellar/agyx/<version>/<rest> maps to <prefix>/opt/agyx/<rest> when that
# exists. Any other (resolved) path is kept as it is, e.g. a git checkout.
agyx_stable() {
  case $1 in
    */Cellar/agyx/*/*)
      _pre=${1%%/Cellar/agyx/*}; _rest=${1#*/Cellar/agyx/}; _rest=${_rest#*/}
      if [ -e "$_pre/opt/agyx/$_rest" ]; then AGYX_STABLE=$_pre/opt/agyx/$_rest; return 0; fi ;;
  esac
  AGYX_STABLE=$1
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

agyx_tilde() { # print $1 with the real home shown as ~ (paths outside it stay absolute)
  # shellcheck disable=SC2088 # a literal ~ is intended
  case $1 in
    "$R") printf '~' ;;
    "$R"/*) printf '~/%s' "${1#"$R"/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# The message for "agy is not installed" (also used when AGYX_REAL_AGY is unusable); exits.
agyx_missing_agy() {
  if [ -n "${AGYX_REAL_AGY-}" ]; then
    echo "agyx: AGYX_REAL_AGY=$AGYX_REAL_AGY is not an executable file (or is agyx itself); set it to the real agy" >&2
    exit 1
  fi
  {
    echo "agyx: agyx needs the Antigravity CLI (agy) first, and it is not installed."
    echo "Install it with the official command:  curl -fsSL https://antigravity.google/cli/install.sh | bash"
    echo "(docs: https://antigravity.google/docs/cli/overview)"
    echo "Then run agyx again. If agy is installed somewhere else, set AGYX_REAL_AGY=/path/to/agy."
  } >&2
  exit 1
}

# Nothing is written to the user's file system until the user agreed once. "Set up" = the data dir
# exists. Commands that write call this first. Without a terminal (stdin and stderr) it refuses;
# AGYX_ASSUME_YES=1 skips the question. AGYX_TTY=<file> is for tests only: it replaces the terminal
# check and /dev/tty as the place the answer is read from.
agyx_gate() {
  [ -d "$data" ] && return 0
  # agy first: without it there is nothing to set up (no prompt, nothing written)
  if [ -n "${AGYX_REAL_AGY-}" ]; then
    _found=$AGYX_REAL_AGY
    { [ -f "$_found" ] && [ -x "$_found" ] && [ ! "$_found" -ef "$AGYX_SHIM" ]; } || agyx_missing_agy
  else
    agyx_scan_path || agyx_missing_agy
  fi
  if [ "${AGYX_ASSUME_YES-}" != 1 ]; then
    if [ -z "${AGYX_TTY-}" ] && { [ ! -t 0 ] || [ ! -t 2 ]; }; then
      die "agyx is not set up yet. Run agyx once in a terminal to set it up (or set AGYX_ASSUME_YES=1)."
    fi
    agyx_set_links_file
    {
      echo "agyx will set up:"
      echo "  $(agyx_tilde "$data")/  profiles (one HOME and keychain per account), a link to agy at $(agyx_tilde "$_found")"
      echo "  $(agyx_tilde "$data")/bin/agy  entry for apps that need a binary named agy"
      echo "  $(agyx_tilde "$AGYX_LINKS_FILE")  home entries linked into every profile (editable)"
      echo "Profiles share your ~/.gemini settings and history; your login keychain is not touched."
      printf 'Continue? [Y/n] '
    } >&2
    _ans=
    read -r _ans < "${AGYX_TTY:-/dev/tty}" || [ -n "$_ans" ] || _ans=n
    case $_ans in ''|[Yy]*) ;; *) echo >&2; die "not set up; nothing was written." ;; esac
  fi
  (umask 077; mkdir -p "$data") || die "cannot create $data"
}
