# shellcheck shell=sh
# shellcheck disable=SC2154,SC2034 # R, P, data and AGYX_SHIM are set by callers
# R = real HOME; P = profile app directory. Never read or copy a token.
AGYX_VERSION=0.2.0-beta.3 # the one place the version lives (the formula's url tag must match)

agyx_private() {
  case $1 in antigravity-oauth-token|settings.json|jetski_state.pbtxt|jetbox_summaries_proto.pb) return 0 ;; esac
  return 1
}

agyx_sidecar() {
  case $1 in *-wal|*-shm|*-journal) return 0 ;; esac
  return 1
}

# The known shared layout; seed before the first native launch, not the next one.
agyx_shared_entries() {
  case $1 in
    dirs) printf '%s\n' annotations bin brain builtin cache conversations crashes implicit presence sidecar_data ;;
    files) printf '%s\n' conversation_summaries.db history.jsonl installation_id ;;
  esac
}

# A subshell keeps recursive merge paths from overwriting their caller's variables.
agyx_merge_tree() (
  if [ -d "$1" ] && [ ! -L "$1" ] && [ -d "$2" ] && [ ! -L "$2" ]; then
    for _item in "$1"/* "$1"/.[!.]* "$1"/..?*; do
      [ -e "$_item" ] || [ -L "$_item" ] || continue
      agyx_merge_tree "$_item" "$2/${_item##*/}" "$3/${_item##*/}" || return 1
    done
    rmdir "$1"
  elif [ ! -e "$2" ] && [ ! -L "$2" ]; then
    mv "$1" "$2"
  else
    mkdir -p "${3%/*}" || return 1
    if [ "$1" -nt "$2" ]; then mv "$2" "$3" && mv "$1" "$2"
    else mv "$1" "$3"; fi
  fi
)

# Moving existing known entries also needs consent and a stopped native writer.
agyx_needs_repair() (
  for _dir in "$data"/profiles/*; do
    [ -d "$_dir/antigravity-cli" ] && [ ! -L "$_dir" ] && [ ! -L "$_dir/antigravity-cli" ] || continue
    for _entry in "$_dir/antigravity-cli"/* "$_dir/antigravity-cli"/.[!.]* "$_dir/antigravity-cli"/..?*; do
      [ -e "$_entry" ] && [ ! -L "$_entry" ] || continue
      _name=${_entry##*/}
      agyx_private "$_name" && continue
      agyx_sidecar "$_name" && continue
      for _known in $(agyx_shared_entries dirs) $(agyx_shared_entries files); do [ "$_name" != "$_known" ] || return 0; done
      [ ! -e "$_shared/$_name" ] && [ ! -L "$_shared/$_name" ] || return 0
      for _other in "$data"/profiles/*; do
        [ "$_other" != "$_dir" ] && [ ! -L "$_other" ] && [ ! -L "$_other/antigravity-cli" ] || continue
        [ ! -e "$_other/antigravity-cli/$_name" ] || [ -L "$_other/antigravity-cli/$_name" ] || return 0
      done
    done
  done
  return 1
)

# A missing DB with surviving sidecars needs manual recovery, not an empty replacement.
agyx_no_orphan_sidecars() {
  for _suffix in -wal -shm -journal; do
    if [ -e "$1$_suffix" ] || [ -L "$1$_suffix" ]; then
      echo "agyx: orphan shared SQLite sidecar: $1$_suffix; repair stopped" >&2
      return 1
    fi
  done
}

agyx_repair_shared() (
  agyx_needs_repair || return 0
  if [ "${AGYX_ASSUME_YES-}" != 1 ]; then
    [ -n "${AGYX_TTY-}" ] || { [ -t 0 ] && [ -t 2 ]; } || {
      echo "agyx: shared entries need repair; run once in a terminal (or set AGYX_ASSUME_YES=1); inspect agyx doctor; nothing repaired" >&2
      return 1
    }
    {
      echo "agyx will repair shared entries for all profiles. Close all agy sessions first."
      echo "Directory conflicts: newer wins (shared wins ties); the other copy goes to the Trash."
      echo "History: append missing lines. Shared DB/other files stay; profile copies go to the Trash."
      echo "The four private files are never touched."
      printf 'Continue? [Y/n] '
    } >&2
    _ans=
    read -r _ans < "${AGYX_TTY:-/dev/tty}" || [ -n "$_ans" ] || _ans=n
    case $_ans in ''|[Yy]*) ;; *) echo "agyx: shared repair cancelled; nothing repaired" >&2; return 1 ;; esac
  fi
  # Check after consent: native writers may have been running while the question was open.
  set -- "$_shared/conversation_summaries.db"
  for _dir in "$data"/profiles/*; do set -- "$@" "$_dir/antigravity-cli/conversation_summaries.db"; done
  _pids=$(/usr/sbin/lsof -nP -t "$@" 2>/dev/null | tr '\n' ' ')
  [ -z "$_pids" ] || { echo "agyx: close agy before shared repair (PIDs: $_pids); nothing repaired" >&2; return 1; }
  mkdir -p "${AGYX_TRASH_DIR:-$R/.Trash}" || return 1
  _trash=$(mktemp -d "${AGYX_TRASH_DIR:-$R/.Trash}/agyx-shared-repair-XXXXXX") || return 1
  for _dir in "$data"/profiles/*; do
    [ -d "$_dir/antigravity-cli" ] && [ ! -L "$_dir" ] && [ ! -L "$_dir/antigravity-cli" ] || continue
    for _entry in "$_dir/antigravity-cli"/* "$_dir/antigravity-cli"/.[!.]* "$_dir/antigravity-cli"/..?*; do
      [ -e "$_entry" ] && [ ! -L "$_entry" ] || continue
      _name=${_entry##*/}
      agyx_private "$_name" && continue
      agyx_sidecar "$_name" && continue
      _dest=$_shared/$_name _saved=$_trash/${_dir##*/}/$_name
      [ ! -L "$_dest" ] || { echo "agyx: unexpected shared link: $_dest; repair stopped" >&2; return 1; }
      _db_dest=$_dest
      case $_name in *.db) [ -e "$_dest" ] || agyx_no_orphan_sidecars "$_dest" || return 1 ;; esac
      if [ ! -e "$_dest" ]; then mv "$_entry" "$_dest" || return 1
      elif [ -d "$_entry" ] && [ -d "$_dest" ]; then
        agyx_merge_tree "$_entry" "$_dest" "$_saved" || return 1
      else
        mkdir -p "${_saved%/*}" || return 1
        if [ "$_name" = history.jsonl ]; then
          [ -f "$_entry" ] && [ -f "$_dest" ] || return 1
          _add=$(mktemp "$_trash/.history-XXXXXX") || return 1
          LC_ALL=C awk 'FILENAME == ARGV[1] {seen[$0]=1; next} !seen[$0]++ {print}' "$_dest" "$_entry" > "$_add" || return 1
          if [ -s "$_add" ]; then
            if [ -s "$_dest" ] && [ "$(tail -c 1 "$_dest" | wc -l)" -eq 0 ]; then printf '\n' >> "$_dest" || return 1; fi
            cat "$_add" >> "$_dest" || return 1
          fi
          rm "$_add" || return 1
        fi
        mv "$_entry" "$_saved" || return 1
        _db_dest=$_saved
      fi
      case $_name in *.db)
        for _suffix in -wal -shm -journal; do
          [ -e "$_entry$_suffix" ] || [ -L "$_entry$_suffix" ] || continue
          mv "$_entry$_suffix" "$_db_dest$_suffix" || return 1
        done ;;
      esac
      ln -s "$_dest" "$_entry" || return 1
    done
  done
  echo "agyx: shared entries repaired; displaced copies are in $_trash" >&2
)

# Serialize preparation/repair, not native agy sessions. Never keep the lock while agy runs.
agyx_sync_app() (
  umask 077
  _shared=$R/.gemini/antigravity-cli
  mkdir -p "$P" "$_shared" || return 1
  _lock=$R/.gemini/.agyx-shared-prepare-lock _tries=${AGYX_LOCK_TRIES:-100}
  # ponytail: global spin-wait lock (up to ~5s); switch to flock/shlock only if launch concurrency outgrows this
  while ! mkdir "$_lock" 2>/dev/null; do
    _tries=$((_tries - 1))
    [ "$_tries" -gt 0 ] || { echo "agyx: shared preparation is busy; if no agyx is preparing, remove stale lock with: rmdir $_lock" >&2; return 1; }
    sleep 0.05
  done
  trap 'rmdir "$_lock"' EXIT
  trap 'exit 1' HUP INT TERM
  agyx_repair_shared || return 1
  for _n in $(agyx_shared_entries dirs); do mkdir -p "$_shared/$_n" || return 1; done
  for _n in $(agyx_shared_entries files); do
    [ ! -e "$_shared/$_n" ] && [ ! -L "$_shared/$_n" ] || continue
    case $_n in *.db) agyx_no_orphan_sidecars "$_shared/$_n" || return 1 ;; esac
    # SQLite initializes a zero-byte DB; an empty JSONL stream has no records.
    if [ "$_n" = installation_id ]; then
      _id=$(uuidgen) || return 1
      printf %s "$_id" | tr '[:upper:]' '[:lower:]' > "$_shared/$_n" || return 1
    else : > "$_shared/$_n" || return 1; fi
  done
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
)

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
      [ ! -L "$_p" ] && [ -f "$_p" ] || echo "  antigravity-cli $_n: WARNING private entry is not a regular file"
    elif [ -L "$_p" ] && [ "$(readlink "$_p")" = "$_shared/$_n" ] && [ -e "$_p" ]; then
      echo "  antigravity-cli $_n: linked"
    elif [ -L "$_p" ]; then echo "  antigravity-cli $_n: WARNING broken or unexpected link"
    elif [ -e "$_shared/$_n" ] || [ -L "$_shared/$_n" ]; then echo "  antigravity-cli $_n: DRIFT (present on both sides; left untouched)"
    else echo "  antigravity-cli $_n: local (adopted on next launch)"; fi
  done
  for _s in "$_shared"/* "$_shared"/.[!.]* "$_shared"/..?*; do
    [ -e "$_s" ] || [ -L "$_s" ] || continue
    _n=${_s##*/}
    agyx_sidecar "$_n" && continue
    agyx_private "$_n" && continue
    [ -e "$P/$_n" ] || [ -L "$P/$_n" ] || echo "  antigravity-cli $_n: missing link (linked on next launch)"
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
    (umask 077; mkdir -p "$_d/antigravity-cli") || die "cannot create profile app directory"
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

# Resolve invocation links, including relative links; native agy must not see a cache alias.
agyx_resolve_path() {
  _resolved=$1 _hops=0
  while [ -L "$_resolved" ]; do
    _hops=$((_hops + 1)); [ "$_hops" -le 40 ] || return 1
    _link=$(readlink "$_resolved") || return 1
    case $_link in /*) _resolved=$_link ;; *) _resolved=$(dirname "$_resolved")/$_link ;; esac
  done
  _parent=$(cd "$(dirname "$_resolved")" && pwd -P) || return 1
  _resolved=$_parent/$(basename "$_resolved")
}

# Current and other installed/copied agyx shims must never be selected as native agy.
agyx_is_shim() {
  [ "$1" -ef "$AGYX_SHIM" ] && return 0
  case $1 in */bin/agy|*/bin/agyx)
    [ -f "${1%/*}/../runtime/sync.sh" ] &&
      head -c 128 "$1" | grep -q '^# agyx' &&
      grep -q '^AGYX_VERSION=' "${1%/*}/../runtime/sync.sh" && return 0 ;;
  esac
  return 1
}

agyx_real_candidate() {
  [ -f "$1" ] && [ -x "$1" ] || return 1
  agyx_resolve_path "$1" || return 1
  agyx_is_shim "$_resolved" && return 1
  real=$_resolved
}

# Search every launch, then try the official install location for GUI apps' minimal PATH.
agyx_find_real() {
  if [ -n "${AGYX_REAL_AGY-}" ]; then agyx_real_candidate "$AGYX_REAL_AGY"; return; fi
  _search=${PATH-}
  while :; do
    _p=${_search%%:*}
    if [ -n "$_p" ] && agyx_real_candidate "$_p/agy"; then return 0; fi
    case $_search in *:*) _search=${_search#*:} ;; *) break ;; esac
  done
  agyx_real_candidate "$R/.local/bin/agy"
}

# Only links to agyx code (including removed Homebrew versions) belong to us.
agyx_own_link() {
  [ -L "$1" ] || return 1
  _link=$(readlink "$1") || return 1
  case $_link in
    */Cellar/agyx/*/libexec/bin/agy|*/Cellar/agyx-beta/*/libexec/bin/agy|*/opt/agyx/libexec/bin/agy|*/opt/agyx-beta/libexec/bin/agy) return 0 ;;
  esac
  agyx_resolve_path "$1" 2>/dev/null && agyx_is_shim "$_resolved"
}

agyx_clean_old_entry() {
  if [ -L "$data/real-agy" ]; then
    case $(readlink "$data/real-agy") in /*/agy) rm "$data/real-agy" || return 1 ;; esac
  fi
  [ -d "$data/bin" ] && [ ! -L "$data/bin" ] && agyx_own_link "$data/bin/agy" || return 0
  (umask 077; mkdir -p "${AGYX_TRASH_DIR:-$R/.Trash}") || return 1
  _entry_trash=$(mktemp -d "${AGYX_TRASH_DIR:-$R/.Trash}/agyx-entry-layout-XXXXXX") || return 1
  mv "$data/bin/agy" "$_entry_trash/agy" || return 1
  [ -z "$(find "$data/bin" -prune -empty -print)" ] || mv "$data/bin" "$_entry_trash/bin" || return 1
}

# <data>/agy is the only app entry. Preserve unrelated files/links at that path.
agyx_ensure_entry() {
  agyx_clean_old_entry || return 1
  [ "$data/agy" -ef "$AGYX_SHIM" ] && return 0
  if [ -e "$data/agy" ] || [ -L "$data/agy" ]; then agyx_own_link "$data/agy" || return 0; fi
  (umask 077; mkdir -p "$data") && ln -sfn "$AGYX_SHIM" "$data/agy"
}

# Sets AGYX_STABLE to the path agyx stores or passes on for itself. Homebrew keeps each version in
# its own Cellar directory and deletes old ones, while <prefix>/opt/<formula> is a stable link to
# the current version: <prefix>/Cellar/<formula>/<version>/<rest> maps to <prefix>/opt/<formula>/<rest>
# when that exists (the formula is agyx or the beta agyx-beta). Any other (resolved) path is kept
# as it is, e.g. a git checkout.
agyx_stable() {
  case $1 in
    */Cellar/*/*)
      _name=${1#*/Cellar/}; _name=${_name%%/*}
      _pre=${1%%/Cellar/$_name/*}; _rest=${1#*/Cellar/$_name/}; _rest=${_rest#*/}
      if [ -e "$_pre/opt/$_name/$_rest" ]; then AGYX_STABLE=$_pre/opt/$_name/$_rest; return 0; fi ;;
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
  agyx_find_real || agyx_missing_agy
  if [ "${AGYX_ASSUME_YES-}" != 1 ]; then
    if [ -z "${AGYX_TTY-}" ] && { [ ! -t 0 ] || [ ! -t 2 ]; }; then
      die "agyx is not set up yet. Run agyx once in a terminal to set it up (or set AGYX_ASSUME_YES=1)."
    fi
    {
      echo "agyx will set up:"
      echo "  $(agyx_tilde "$data")/  profiles (private app settings and file login per account)"
      echo "  $(agyx_tilde "$data")/agy  entry for apps that need a binary named agy"
      echo "Profiles use your real HOME and share conversations and history; your login keychain is not touched."
      printf 'Continue? [Y/n] '
    } >&2
    _ans=
    read -r _ans < "${AGYX_TTY:-/dev/tty}" || [ -n "$_ans" ] || _ans=n
    case $_ans in ''|[Yy]*) ;; *) echo >&2; die "not set up; nothing was written." ;; esac
  fi
  (umask 077; mkdir -p "$data") || die "cannot create $data"
}
