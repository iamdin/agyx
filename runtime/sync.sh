# shellcheck shell=sh
# shellcheck disable=SC2154,SC2034 # R, P, data and AGYX_SHIM are set by callers
# R = real HOME; P = profile app directory. Never read or copy a token.
AGYX_VERSION=0.1.3 # the one place the version lives (the formula's url tag must match)

agyx_private() {
  case $1 in antigravity-oauth-token|settings.json|jetski_state.pbtxt|jetbox_summaries_proto.pb) return 0 ;; esac
  return 1
}

agyx_sidecar() {
  case $1 in *-wal|*-shm|*-journal) return 0 ;; esac
  return 1
}

# Link shared entries, then adopt new agy entries without overwriting either side.
agyx_sync_app() {
  _shared=$R/.gemini/antigravity-cli
  (umask 077; mkdir -p "$P" "$_shared") || return 1
  for _s in "$_shared"/* "$_shared"/.[!.]* "$_shared"/..?*; do
    [ -e "$_s" ] || [ -L "$_s" ] || continue
    _n=${_s##*/}
    agyx_sidecar "$_n" && continue
    agyx_private "$_n" && continue
    [ -e "$P/$_n" ] || [ -L "$P/$_n" ] || ln -s "$_s" "$P/$_n" || return 1
  done
  for _p in "$P"/* "$P"/.[!.]* "$P"/..?*; do
    [ -e "$_p" ] || [ -L "$_p" ] || continue
    _n=${_p##*/}
    if agyx_sidecar "$_n"; then
      [ ! -L "$_p" ] || [ -e "$_p" ] || rm "$_p" || return 1
      continue
    fi
    if agyx_private "$_n"; then
      [ ! -L "$_p" ] && [ -f "$_p" ] || {
        echo "agyx: private entry $_p must be a regular file, not a link or directory" >&2
        return 1
      }
    elif [ ! -L "$_p" ] && [ ! -e "$_shared/$_n" ] && [ ! -L "$_shared/$_n" ]; then
      mv -n "$_p" "$_shared/" || return 1
      # Another launch may have adopted the same name; leave this copy as drift.
      [ -e "$_p" ] || ln -s "$_shared/$_n" "$_p" || return 1
    fi
  done
}

# Relative to agy's ~/.gemini, including custom data dirs outside HOME. Both dirs must exist.
agyx_app_arg() {
  _from=$(cd "$R/.gemini" && pwd -P) || return 1
  _to=$(cd "$P" && pwd -P) || return 1
  _up=
  while :; do
    case $_to in "$_from"/*) break ;; esac
    [ "$_from" != / ] || { _from=; break; }
    _from=${_from%/*}; [ -n "$_from" ] || _from=/
    _up=../$_up
  done
  AGYX_APP_ARG=$_up${_to#"$_from"/}
}

agyx_report() {
  _shared=$R/.gemini/antigravity-cli
  for _p in "$P"/* "$P"/.[!.]* "$P"/..?*; do
    [ -e "$_p" ] || [ -L "$_p" ] || continue
    _n=${_p##*/}
    agyx_sidecar "$_n" && continue
    if agyx_private "$_n"; then
      [ ! -L "$_p" ] && [ -f "$_p" ] || echo "  app $_n: WARNING private entry is not a regular file"
    elif [ -L "$_p" ] && [ "$(readlink "$_p")" = "$_shared/$_n" ] && [ -e "$_p" ]; then
      echo "  app $_n: linked"
    elif [ -L "$_p" ]; then echo "  app $_n: WARNING broken or unexpected link"
    elif [ -e "$_shared/$_n" ] || [ -L "$_shared/$_n" ]; then echo "  app $_n: DRIFT (present on both sides; left untouched)"
    else echo "  app $_n: local (adopted on next launch)"; fi
  done
  for _s in "$_shared"/* "$_shared"/.[!.]* "$_shared"/..?*; do
    [ -e "$_s" ] || [ -L "$_s" ] || continue
    _n=${_s##*/}
    agyx_sidecar "$_n" && continue
    agyx_private "$_n" && continue
    [ -e "$P/$_n" ] || [ -L "$P/$_n" ] || echo "  app $_n: missing link (linked on next launch)"
  done
}

# Email comes only from this login's log, never from its token or another profile's logs.
agyx_email_file() {
  [ -f "$1" ] || return 0
  _el=$(grep applyAuthResult "$1" 2>/dev/null | sed -n 's/.*email=\([^][ ,;"}()]*\).*/\1/p' | tail -n 1 | tr -d '[:cntrl:]')
  case $_el in *[[:space:]]*) ;; *) printf '%s' "$_el" ;; esac
}

agyx_set_links_file() {
  case ${XDG_CONFIG_HOME-} in
    /*) AGYX_LINKS_FILE=$XDG_CONFIG_HOME/agyx/symlinks ;;
    *) AGYX_LINKS_FILE=$R/.config/agyx/symlinks ;;
  esac
}

# Only remove the exact blocker created by 0.1.3, never plain agy's file or an unknown directory.
agyx_remove_blocker() {
  _block=$R/.gemini/antigravity-cli/antigravity-oauth-token
  [ -d "$_block" ] && [ ! -L "$_block" ] && [ "$(ls -A "$_block")" = README ] && [ ! -L "$_block/README" ] || return 0
  if printf '%s\n' \
    'agyx keeps this directory here so the Antigravity CLI (agy) cannot write a token file at this path:' \
    'all agyx profiles share this ~/.gemini, so such a file would be shared by every Google account.' \
    "Logins live only in each profile's own keychain. Delete this directory only after uninstalling agyx." | cmp -s - "$_block/README"; then
    rm "$_block/README" && rmdir "$_block" || return 1
  fi
}

agyx_delete_old_keychain() {
  _home=$1/home
  _kc=$_home/Library/Keychains/login.keychain-db
  [ -e "$_kc" ] || return 0
  [ ! -L "$_home" ] && [ ! -L "$_home/Library" ] && [ ! -L "$_home/Library/Keychains" ] && [ ! -L "$_kc" ] || die "unsafe legacy keychain path: $_kc"
  HOME=$_home "${AGYX_SECURITY:-/usr/bin/security}" delete-keychain "$_kc" >/dev/null 2>&1 || die "cannot delete old profile keychain: $_kc; migration stopped"
}

agyx_migrate() {
  _old=
  for _d in "$data"/profiles/*; do
    [ -d "$_d/home" ] || continue
    [ ! -L "$_d" ] && [ ! -L "$_d/home" ] || die "unsafe legacy profile: $_d"
    _old=1
  done
  [ -n "$_old" ] || return 0
  if [ "${AGYX_ASSUME_YES-}" != 1 ]; then
    [ -n "${AGYX_TTY-}" ] || { [ -t 0 ] && [ -t 2 ]; } || die "old profiles need migration; run once in a terminal (or set AGYX_ASSUME_YES=1); nothing changed"
    {
      echo "agyx will migrate all old profiles to real HOME and private file logins."
      echo "Each profile must sign in again. Old profile keychains will be deleted; home/ goes to the Trash."
      echo "Email and logs stay; the old whitelist goes to the Trash and the agyx token blocker is removed."
      printf 'Continue? [Y/n] '
    } >&2
    _ans=
    read -r _ans < "${AGYX_TTY:-/dev/tty}" || [ -n "$_ans" ] || _ans=n
    case $_ans in ''|[Yy]*) ;; *) die "migration cancelled; nothing changed" ;; esac
  fi
  (umask 077; mkdir -p "${AGYX_TRASH_DIR:-$R/.Trash}") || die "cannot create Trash directory"
  # Delete before moving, with the old HOME and explicit keychain path only.
  for _d in "$data"/profiles/*; do
    [ -d "$_d/home" ] || continue
    agyx_delete_old_keychain "$_d"
    _trash=$(mktemp -d "${AGYX_TRASH_DIR:-$R/.Trash}/agyx-${_d##*/}-$(date +%Y%m%d%H%M%S)-XXXXXX") || die "cannot create migration Trash directory"
    mv "$_d/home" "$_trash/home" || die "cannot move old profile home to the Trash"
    (umask 077; mkdir -p "$_d/app") || die "cannot create profile app directory"
    echo "agyx: profile ${_d##*/}: old home moved to $_trash; sign in again with agyx profile login ${_d##*/}" >&2
  done
  agyx_remove_blocker || die "cannot remove old token blocker"
  agyx_set_links_file
  [ ! -f "$AGYX_LINKS_FILE" ] || mv "$AGYX_LINKS_FILE" "$_trash/symlinks" || die "cannot move old whitelist to the Trash"
}

# Management subcommands of bin/agyx; they are also the reserved profile names (the only list).
agyx_subcommand() {
  case $1 in doctor|profile|uninstall) return 0 ;; esac
  return 1
}

# A future agy may ignore WSL and fall back to keychain-first, mixing accounts.
agyx_check_storage() {
  case $1 in /*) _storage_log=$1 ;; *) _storage_log=$PWD/$1 ;; esac
  if ! grep -Fq 'Using file-based token storage' "$_storage_log" 2>/dev/null; then
    echo "agyx: WARNING: file-based token storage NOT confirmed in $1. Stop using profiles until agy compatibility is checked: keychain fallback can mix accounts and delete the profile token file." >&2
  fi
}

# Per-profile agy log: <profile dir>/log/cli-YYYYMMDD_HHMMSS.log, a new file per launch.
# agyx checks storage mode after exit; it never links or prunes logs.
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
  [ "${1-}" != readonly ] || return 0
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
    {
      echo "agyx will set up:"
      echo "  $(agyx_tilde "$data")/  profiles (private app settings and file login per account), a link to agy at $(agyx_tilde "$_found")"
      echo "  $(agyx_tilde "$data")/bin/agy  entry for apps that need a binary named agy"
      echo "Profiles use your real HOME and share conversations and history; your login keychain is not touched."
      printf 'Continue? [Y/n] '
    } >&2
    _ans=
    read -r _ans < "${AGYX_TTY:-/dev/tty}" || [ -n "$_ans" ] || _ans=n
    case $_ans in ''|[Yy]*) ;; *) echo >&2; die "not set up; nothing was written." ;; esac
  fi
  (umask 077; mkdir -p "$data") || die "cannot create $data"
}
