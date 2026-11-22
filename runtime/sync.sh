# shellcheck shell=sh
# shellcheck disable=SC2154,SC2034,SC3013 # R/P/data/AGYX_* set by callers; -ef/-nt are POSIX.1-2024
# R = real HOME; P = profile app directory. Never read or copy a token.
AGYX_VERSION=0.2.1 # the one place the version lives (the formula's url tag must match)
AGYX_SHARED_DIRS='annotations bin brain builtin conversations implicit mcp presence sidecar_data skills'
AGYX_SHARED_FILES='conversation_summaries.db history.jsonl installation_id'
if [ -d /System/Library ]; then AGYX_OS=Darwin
elif [ -d /proc ]; then AGYX_OS=Linux
else AGYX_OS=$(uname -s 2>/dev/null)
fi

agyx_valid_name() {
  case ${1-} in ''|*[!abcdefghijklmnopqrstuvwxyz0123456789_-]*|[!abcdefghijklmnopqrstuvwxyz]*) return 1 ;; esac
  [ "${#1}" -le 32 ]
}

# Management subcommands of bin/agyx; they are also the reserved profile names (the only list).
agyx_subcommand() {
  case ${1-} in doctor|profile|uninstall) return 0 ;; esac
  return 1
}

agyx_has_tty() { [ -n "${AGYX_TTY-}" ] || { [ -t 0 ] && [ -t 2 ]; }; }

# $1 = y (default Yes) or n (default No), $2 = prompt. Caller checks agyx_has_tty first.
agyx_ask() {
  [ "${AGYX_ASSUME_YES-}" = 1 ] && return 0
  printf '%s' "$2" >&2
  _ans=''
  read -r _ans < "${AGYX_TTY:-/dev/tty}" || [ -n "$_ans" ] || _ans=n
  case $1:$_ans in y:|y:[Yy]*|n:[Yy]*) return 0 ;; esac
  return 1
}

# True when agy natively selects file-based token storage without any synthetic environment variable:
# any SSH session, container, existing WSL session, or headless Linux without a D-Bus session bus socket.
agyx_native_file_storage() {
  [ -n "${SSH_TTY-}${SSH_CLIENT-}${SSH_CONNECTION-}${WSL_DISTRO_NAME-}${WSL_INTEROP-}" ] && return 0
  [ -e "${AGYX_DOCKERENV:-/.dockerenv}" ] && return 0
  if [ "$AGYX_OS" = Linux ]; then
    case ${DBUS_SESSION_BUS_ADDRESS-} in
      ''|none:|disabled:)
        _bus=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/bus
        [ ! -S "$_bus" ] && return 0 ;;
    esac
  fi
  return 1
}

# Portable across macOS and Linux: Trash dir, octal mode, UUID, and open-file PID lookup.
agyx_trash_base() {
  if [ -n "${AGYX_TRASH_DIR-}" ]; then printf '%s' "$AGYX_TRASH_DIR"
  elif [ -d "$R/.Trash" ] || [ "$AGYX_OS" = Darwin ]; then printf '%s' "$R/.Trash"
  else
    case ${XDG_DATA_HOME-} in /*) printf '%s/Trash/files' "$XDG_DATA_HOME" ;; *) printf '%s/.local/share/Trash/files' "$R" ;; esac
  fi
}

agyx_mode() {
  if [ "$AGYX_OS" = Darwin ]; then stat -f %Lp "$1" 2>/dev/null
  else stat -c %a "$1" 2>/dev/null
  fi
}

agyx_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then IFS= read -r _u < /proc/sys/kernel/random/uuid && printf '%s' "$_u"
  elif command -v uuidgen >/dev/null 2>&1; then uuidgen | tr '[:upper:]' '[:lower:]'
  else awk 'BEGIN{srand(); printf "%04x%04x-%04x-4%03x-a%03x-%04x%04x%04x", rand()*65536, rand()*65536, rand()*65536, rand()*4096, rand()*4096, rand()*65536, rand()*65536, rand()*65536}'
  fi
}

agyx_open_pids() {
  _lsof=''
  if [ -x /usr/sbin/lsof ]; then _lsof=/usr/sbin/lsof
  elif command -v lsof >/dev/null 2>&1; then _lsof=$(command -v lsof)
  fi
  if [ -n "$_lsof" ]; then
    "$_lsof" -nP -t "$@" 2>/dev/null | sort -u | tr '\n' ' '
  elif command -v fuser >/dev/null 2>&1; then
    fuser "$@" 2>/dev/null | tr -s '[:space:]' '\n' | grep -E '^[0-9]+$' | sort -u | tr '\n' ' '
  elif [ -d /proc ]; then
    for _fd in /proc/[0-9]*/fd/* /proc/[0-9]*/exe; do
      [ -L "$_fd" ] || continue
      for _tgt in "$@"; do
        [ -e "$_tgt" ] && [ "$_fd" -ef "$_tgt" ] || continue
        _p=${_fd#/proc/}; printf '%s\n' "${_p%%/*}"
      done
    done | sort -u | tr '\n' ' '
  fi
}

# Strict per-account regular files (token and atomic-rename state).
agyx_private_file() {
  case $1 in antigravity-oauth-token|settings.json|jetski_state.pbtxt|jetbox_summaries_proto.pb) return 0 ;; esac
  return 1
}

# All per-account entries (never linked from ~/.gemini/antigravity-cli):
# cache holds default_project_id.txt; daemon holds remote-control discovery/tokens; log + cli.log are managed & pruned by native agy per profile.
agyx_private() {
  agyx_private_file "$1" && return 0
  case $1 in cache|crashes|daemon|log|cli.log|updater|last_check.timestamp) return 0 ;; esac
  return 1
}

agyx_sidecar() {
  case $1 in *-wal|*-shm|*-journal) return 0 ;; esac
  return 1
}

agyx_is_known_shared() {
  case $1 in annotations|bin|brain|builtin|conversations|implicit|mcp|presence|sidecar_data|skills|conversation_summaries.db|history.jsonl|installation_id) return 0 ;; esac
  return 1
}

# The known shared layout; seed before the first native launch, not the next one.
agyx_shared_entries() {
  case $1 in
    dirs) printf '%s\n' $AGYX_SHARED_DIRS ;;
    files) printf '%s\n' $AGYX_SHARED_FILES ;;
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

# Moving existing known entries also needs consent and a stopped native writer. Zero forks when clean.
agyx_needs_repair() (
  for _dir in "$data"/profiles/*; do
    [ -d "$_dir/antigravity-cli" ] && [ ! -L "$_dir" ] && [ ! -L "$_dir/antigravity-cli" ] || continue
    for _entry in "$_dir/antigravity-cli"/* "$_dir/antigravity-cli"/.[!.]* "$_dir/antigravity-cli"/..?*; do
      [ ! -L "$_entry" ] && [ -e "$_entry" ] || continue
      _name=${_entry##*/}
      agyx_private "$_name" && continue
      agyx_sidecar "$_name" && continue
      agyx_is_known_shared "$_name" && return 0
      [ ! -e "$_shared/$_name" ] && [ ! -L "$_shared/$_name" ] || return 0
      for _other in "$data"/profiles/*; do
        [ "$_other" != "$_dir" ] && [ ! -L "$_other" ] && [ ! -L "$_other/antigravity-cli" ] || continue
        [ ! -e "$_other/antigravity-cli/$_name" ] || [ -L "$_other/antigravity-cli/$_name" ] || return 0
      done
    done
  done
  return 1
)

# True when $P and $_shared already match in steady state (zero forks, lock-free fast path).
agyx_is_synced() {
  [ -d "$P" ] && [ -d "$_shared" ] || return 1
  for _n in $AGYX_SHARED_DIRS $AGYX_SHARED_FILES; do
    [ -e "$_shared/$_n" ] && [ -L "$P/$_n" ] || return 1
  done
  for _s in "$_shared"/* "$_shared"/.[!.]* "$_shared"/..?*; do
    [ -e "$_s" ] || [ -L "$_s" ] || continue
    _n=${_s##*/}
    agyx_sidecar "$_n" && continue
    agyx_private "$_n" && continue
    [ -e "$P/$_n" ] || [ -L "$P/$_n" ] || return 1
  done
  for _p in "$P"/* "$P"/.[!.]* "$P"/..?*; do
    [ -e "$_p" ] || [ -L "$_p" ] || continue
    _n=${_p##*/}
    if agyx_sidecar "$_n"; then
      [ ! -L "$_p" ] || [ -e "$_p" ] || return 1
      continue
    fi
    if agyx_private_file "$_n"; then
      [ ! -L "$_p" ] && [ -f "$_p" ] || return 1
    elif agyx_private "$_n"; then
      [ ! -L "$_p" ] || [ ! "$_p" -ef "$_shared/$_n" ] || return 1
    else
      [ -L "$_p" ] || return 1
    fi
  done
  return 0
}

# A missing DB with surviving sidecars needs manual recovery, not an empty replacement.
agyx_no_orphan_sidecars() {
  for _suffix in -wal -shm -journal; do
    if [ -e "$1$_suffix" ] || [ -L "$1$_suffix" ]; then
      echo "agyx: orphan shared SQLite sidecar: $1$_suffix; repair stopped" >&2
      return 1
    fi
  done
}

# Move a non-conflicting profile entry into shared (keeping any DB sidecars together) and link it.
agyx_adopt_one() {
  case ${1##*/} in *.db) agyx_no_orphan_sidecars "$2" || return 1 ;; esac
  mv "$1" "$2" || return 1
  case ${1##*/} in *.db)
    for _suffix in -wal -shm -journal; do
      [ -e "$1$_suffix" ] || [ -L "$1$_suffix" ] || continue
      mv "$1$_suffix" "$2$_suffix" || return 1
    done ;;
  esac
  ln -s "$2" "$1"
}

agyx_confirm_repair() {
  [ "${AGYX_ASSUME_YES-}" = 1 ] && return 0
  agyx_has_tty || {
    echo "agyx: shared entries need repair; run once in a terminal (or set AGYX_ASSUME_YES=1); inspect agyx doctor; nothing repaired" >&2
    return 5
  }
  {
    echo "agyx will repair shared entries for all profiles. Close all agy sessions first."
    echo "Directory conflicts: newer wins (shared wins ties); the other copy goes to the Trash."
    echo "History: append missing lines. Shared DB/other files stay; profile copies go to the Trash."
    echo "Private profile entries are never touched."
  } >&2
  agyx_ask y 'Continue? [Y/n] ' || { echo "agyx: shared repair cancelled; nothing repaired" >&2; return 1; }
}

agyx_do_repair() (
  set -- "$_shared/conversation_summaries.db"
  for _dir in "$data"/profiles/*; do set -- "$@" "$_dir/antigravity-cli/conversation_summaries.db"; done
  _pids=$(agyx_open_pids "$@")
  [ -z "$_pids" ] || { echo "agyx: close agy before shared repair (PIDs: ${_pids% }); nothing repaired" >&2; return 1; }
  _tbase=$(agyx_trash_base)
  mkdir -p "$_tbase" || return 1
  _trash=$(mktemp -d "$_tbase/agyx-shared-repair-XXXXXX") || return 1
  for _dir in "$data"/profiles/*; do
    [ -d "$_dir/antigravity-cli" ] && [ ! -L "$_dir" ] && [ ! -L "$_dir/antigravity-cli" ] || continue
    for _entry in "$_dir/antigravity-cli"/* "$_dir/antigravity-cli"/.[!.]* "$_dir/antigravity-cli"/..?*; do
      [ -e "$_entry" ] && [ ! -L "$_entry" ] || continue
      _name=${_entry##*/}
      agyx_private "$_name" && continue
      agyx_sidecar "$_name" && continue
      _dest=$_shared/$_name _saved=$_trash/${_dir##*/}/$_name
      [ ! -L "$_dest" ] || { echo "agyx: unexpected shared link: $_dest; repair stopped" >&2; return 1; }
      if [ ! -e "$_dest" ]; then
        agyx_adopt_one "$_entry" "$_dest" || return 1
        continue
      fi
      if [ -d "$_entry" ] && [ -d "$_dest" ]; then
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
        case $_name in *.db)
          for _suffix in -wal -shm -journal; do
            [ -e "$_entry$_suffix" ] || [ -L "$_entry$_suffix" ] || continue
            mv "$_entry$_suffix" "$_saved$_suffix" || return 1
          done ;;
        esac
      fi
      ln -s "$_dest" "$_entry" || return 1
    done
  done
  echo "agyx: shared entries repaired; displaced copies are in $_trash" >&2
)

# Steady-state launches pass through lock-free with zero forks; mutations serialize under $data/.lock.
agyx_sync_app() (
  umask 077
  _shared=$R/.gemini/antigravity-cli _consented=0
  if agyx_needs_repair; then
    agyx_confirm_repair || return $?
    _consented=1
  elif [ ! -e "$data/.lock" ] && agyx_is_synced; then
    return 0
  fi
  mkdir -p "$P" "$_shared" || return 1
  _lock=$data/.lock _tries=${AGYX_LOCK_TRIES:-250}
  # ponytail: global spin-wait lock (up to ~5s); steady state skips this via agyx_is_synced above
  while ! mkdir "$_lock" 2>/dev/null; do
    _tries=$((_tries - 1))
    [ "$_tries" -gt 0 ] || { echo "agyx: shared preparation is busy; if no agyx is preparing, remove stale lock with: rmdir $_lock" >&2; return 1; }
    sleep 0.02
  done
  trap 'rmdir "$_lock"' EXIT
  trap 'exit 1' HUP INT TERM
  if agyx_needs_repair; then
    [ "$_consented" = 1 ] || [ "${AGYX_ASSUME_YES-}" = 1 ] || {
      echo "agyx: shared entries changed concurrently; run again to confirm repair" >&2
      return 1
    }
    agyx_do_repair || return 1
  fi
  # shellcheck disable=SC2086 # fixed space-separated names in AGYX_SHARED_*
  for _n in $AGYX_SHARED_DIRS; do [ -d "$_shared/$_n" ] || mkdir -p "$_shared/$_n" || return 1; done
  # shellcheck disable=SC2086
  for _n in $AGYX_SHARED_FILES; do
    [ ! -e "$_shared/$_n" ] && [ ! -L "$_shared/$_n" ] || continue
    case $_n in *.db) agyx_no_orphan_sidecars "$_shared/$_n" || return 1 ;; esac
    # SQLite initializes a zero-byte DB; an empty JSONL stream has no records.
    if [ "$_n" = installation_id ]; then
      _id=$(agyx_uuid) && [ -n "$_id" ] || return 1
      printf '%s' "$_id" > "$_shared/$_n" || return 1
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
    if agyx_private_file "$_n"; then
      [ ! -L "$_p" ] && [ -f "$_p" ] || {
        echo "agyx: private entry $_p must be a regular file, not a link or directory" >&2
        return 1
      }
    elif agyx_private "$_n"; then
      if [ -L "$_p" ]; then
        case $(readlink "$_p") in "$_shared/$_n") rm "$_p" || return 1 ;; esac
      fi
    elif [ ! -L "$_p" ] && [ ! -e "$_shared/$_n" ] && [ ! -L "$_shared/$_n" ]; then
      agyx_adopt_one "$_p" "$_shared/$_n" || return 1
    fi
  done
)

# Relative to agy's ~/.gemini, including custom data dirs outside HOME. Both dirs must exist.
agyx_app_arg() {
  _from=$(cd "$R/.gemini" && pwd -P) || return 1
  _to=$(cd "$P" && pwd -P) || return 1
  _up=''
  while :; do
    case $_to in "$_from"/*) break ;; esac
    [ "$_from" != / ] || { _from=''; break; }
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
    if agyx_private_file "$_n"; then
      [ ! -L "$_p" ] && [ -f "$_p" ] || echo "  antigravity-cli $_n: WARNING private entry is not a regular file"
    elif agyx_private "$_n"; then
      if [ -L "$_p" ] && [ "$(readlink "$_p")" = "$_shared/$_n" ]; then
        echo "  antigravity-cli $_n: shared link (detached on next launch)"
      fi
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

# A future agy may ignore WSL and fall back to keychain-first, mixing accounts.
agyx_check_storage() {
  case $1 in /*) _storage_log=$1 ;; *) _storage_log=$PWD/$1 ;; esac
  if ! grep -Fq 'Using file-based token storage' "$_storage_log" 2>/dev/null; then
    echo "agyx: WARNING: file-based token storage NOT confirmed in $1. Stop using profiles until agy compatibility is checked: keychain fallback can mix accounts and delete the profile token file." >&2
  fi
}

# Doctor-only static check on native agy binary (no cache files written to disk).
agyx_check_binary() {
  if ! LC_ALL=C grep -Fq WSL_INTEROP "$1" 2>/dev/null ||
     ! LC_ALL=C grep -Fq app_data_dir "$1" 2>/dev/null ||
     ! LC_ALL=C grep -Fq 'Using file-based token storage' "$1" 2>/dev/null; then
    echo "agyx: WARNING: file-based token storage markers NOT confirmed in $1. Stop using profiles until agy compatibility is checked: keychain fallback can mix accounts and delete the profile token file." >&2
  fi
}

# Check the newest non-empty native log in $1 (<profile>/antigravity-cli) without spawning ls/sort:
# prefer native agy's own cli.log symlink when non-empty; otherwise pick newest in log/*.log via -nt.
agyx_check_recent_log() {
  _cl=$1/cli.log
  if [ -L "$_cl" ] && [ -s "$_cl" ]; then
    _target=$(readlink "$_cl") || _target=''
    case $_target in /*) _cl=$_target ;; ?*) _cl=$1/$_target ;; esac
    agyx_check_storage "$_cl"
    return 0
  fi
  _best=''
  for _f in "$1"/log/*.log; do
    [ -s "$_f" ] || continue
    [ -z "$_best" ] || [ "$_f" -nt "$_best" ] && _best=$_f
  done
  [ -z "$_best" ] || agyx_check_storage "$_best"
}

# Resolve invocation links, including relative links; native agy must not see a cache alias.
agyx_resolve_path() {
  _resolved=$1 _hops=0
  while [ -L "$_resolved" ]; do
    _hops=$((_hops + 1)); [ "$_hops" -le 40 ] || return 1
    _link=$(readlink "$_resolved") || return 1
    case $_link in
      /*) _resolved=$_link ;;
      *) case $_resolved in */*) _resolved=${_resolved%/*}/$_link ;; *) _resolved=$_link ;; esac ;;
    esac
  done
  case $_resolved in */*) _rdir=${_resolved%/*}; _rbase=${_resolved##*/} ;; *) _rdir=.; _rbase=$_resolved ;; esac
  _parent=$(cd "${_rdir:-/}" && pwd -P) || return 1
  _resolved=${_parent%/}/$_rbase
}

# Current and other installed/copied agyx shims must never be selected as native agy (zero forks).
agyx_is_shim() {
  [ "$1" -ef "$AGYX_SHIM" ] && return 0
  case $1 in */bin/agy|*/bin/agyx)
    [ -f "${1%/*}/../runtime/sync.sh" ] || return 1
    _h1='' _h2=''
    { IFS= read -r _h1 && IFS= read -r _h2; } < "$1" 2>/dev/null || :
    case $_h1$_h2 in *'# agyx'*) return 0 ;; esac ;;
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

# <data>/agy is the only app entry. Preserve unrelated files/links at that path.
agyx_ensure_entry() {
  [ "$data/agy" -ef "$AGYX_SHIM" ] && return 0
  if [ -e "$data/agy" ] || [ -L "$data/agy" ]; then agyx_own_link "$data/agy" || return 0; fi
  (umask 077; mkdir -p "$data") && ln -sfn "$AGYX_SHIM" "$data/agy"
}

# Map Homebrew's versioned Cellar path to <prefix>/opt/<formula>/... when it exists (macOS & Linuxbrew).
agyx_stable() {
  case $1 in
    */Cellar/*/*)
      _name=${1#*/Cellar/}; _name=${_name%%/*}
      _pre=${1%%/Cellar/$_name/*}; _rest=${1#*/Cellar/$_name/}; _rest=${_rest#*/}
      if [ -e "$_pre/opt/$_name/$_rest" ]; then AGYX_STABLE=$_pre/opt/$_name/$_rest; return 0; fi ;;
  esac
  AGYX_STABLE=$1
}

agyx_tilde() {
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

# Nothing is written to the user's file system until the user agreed once ("Set up" = data exists).
agyx_gate() {
  [ -d "$data" ] && return 0
  agyx_find_real || agyx_missing_agy
  if [ "${AGYX_ASSUME_YES-}" != 1 ]; then
    agyx_has_tty || { echo "agyx: agyx is not set up yet. Run agyx once in a terminal to set it up (or set AGYX_ASSUME_YES=1)." >&2; exit 5; }
    {
      echo "agyx will set up:"
      echo "  $(agyx_tilde "$data")/  profiles (private app settings and file login per account)"
      echo "  $(agyx_tilde "$data")/agy  entry for apps that need a binary named agy"
      echo "Profiles use your real HOME and share conversations and history; your system keyring is not touched."
    } >&2
    agyx_ask y 'Continue? [Y/n] ' || { echo >&2; die "not set up; nothing was written."; }
  fi
  (umask 077; mkdir -p "$data") || die "cannot create $data"
}
