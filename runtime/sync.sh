# shellcheck shell=sh
# shellcheck disable=SC2034,SC3013 # AGYX_* used by callers; -ef/-nt are POSIX.1-2024
# Shared runtime for bin/agy and bin/agyx. Never read or copy a token.
AGYX_VERSION=0.2.4-beta.1 # the one place the version lives (the formula's url tag must match)
AGYX_SHARED_DIRS='annotations bin brain builtin conversations implicit mcp presence sidecar_data skills'
AGYX_SHARED_FILES='conversation_summaries.db history.jsonl installation_id'
AGYX_HOME=${AGYX_HOME:-${HOME-}}
AGYX_DATA=${AGYX_DATA:-${AGYX_DATA_DIR:-$AGYX_HOME/.local/share/agyx}}
AGYX_SHIM=${AGYX_SHIM-}
AGYX_STABLE='' AGYX_APP_ARG='' AGYX_RESOLVED='' AGYX_REAL=''
AGYX_PROFILE_NAME='' AGYX_PROFILE_SRC='' AGYX_ERR_CODE='' AGYX_ERR_MSG='' AGYX_ERR_HINT=''
if [ -d /System/Library ]; then AGYX_OS=Darwin
elif [ -d /proc ]; then AGYX_OS=Linux
else AGYX_OS=$(uname -s 2>/dev/null)
fi

agyx_init() {
  AGYX_HOME=$HOME
  unset AGYX_REAL_HOME AGY_PROFILE
  AGYX_DATA=${AGYX_DATA_DIR:-$AGYX_HOME/.local/share/agyx}
  agyx_stable "$1"
  AGYX_SHIM=$AGYX_STABLE
}

agyx_valid_name() {
  case ${1-} in ''|*[!abcdefghijklmnopqrstuvwxyz0123456789_-]*|[!abcdefghijklmnopqrstuvwxyz]*) return 1 ;; esac
  [ "${#1}" -le 32 ]
}

# Management subcommands of bin/agyx; they are also the reserved profile names (the only list).
agyx_subcommand() {
  case ${1-} in doctor|profile|uninstall) return 0 ;; esac
  return 1
}

agyx_check_name() {
  if ! agyx_valid_name "${1-}"; then
    AGYX_ERR_CODE=invalid_profile AGYX_ERR_MSG="invalid profile name: ${1-}" AGYX_ERR_HINT=''
    return 2
  fi
  if agyx_subcommand "$1"; then
    AGYX_ERR_CODE=invalid_profile AGYX_ERR_MSG="profile name is reserved: $1" AGYX_ERR_HINT=''
    return 2
  fi
  return 0
}

agyx_check_profile() {
  agyx_check_name "${1-}" || return $?
  if [ -L "$AGYX_DATA/profiles/$1" ] || [ -L "$AGYX_DATA/profiles/$1/antigravity-cli" ]; then
    AGYX_ERR_CODE=symlink_profile AGYX_ERR_MSG="profile '$1' must not be a symlink" AGYX_ERR_HINT=''
    return 1
  fi
  if [ ! -d "$AGYX_DATA/profiles/$1/antigravity-cli" ]; then
    AGYX_ERR_CODE=no_such_profile
    if [ "${2-}" = default ]; then
      AGYX_ERR_MSG="the default profile '$1' (from $AGYX_DATA/default) does not exist"
      AGYX_ERR_HINT="agyx profile default NAME (or create it with: agyx profile login $1)"
    else
      AGYX_ERR_MSG="profile '$1' does not exist"
      AGYX_ERR_HINT="agyx profile login $1"
    fi
    return 3
  fi
  AGYX_PROFILE_NAME=$1
  return 0
}

agyx_resolve_profile() {
  if [ $# -ge 1 ]; then
    AGYX_PROFILE_SRC=flag
    agyx_check_profile "$1" flag
    return $?
  fi
  _rn=${AGYX_PROFILE-} AGYX_PROFILE_SRC=env
  if [ -z "$_rn" ] && [ -f "$AGYX_DATA/default" ]; then
    IFS= read -r _rn < "$AGYX_DATA/default" || :
    AGYX_PROFILE_SRC=default
  fi
  if [ -z "$_rn" ]; then
    _ex=''
    for _d in "$AGYX_DATA"/profiles/*/; do
      [ -d "$_d" ] || continue
      _dn=${_d%/}
      _ex="$_ex ${_dn##*/}"
    done
    AGYX_ERR_CODE=no_profile
    if [ -z "$_ex" ]; then
      AGYX_ERR_MSG="no profiles yet"
      AGYX_ERR_HINT="agyx profile login NAME (for example: agyx profile login work)"
    else
      AGYX_ERR_MSG="no profile selected (existing profiles:$_ex)"
      AGYX_ERR_HINT="agyx profile default NAME (or set AGYX_PROFILE)"
    fi
    return 3
  fi
  agyx_check_profile "$_rn" "$AGYX_PROFILE_SRC"
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

# Portable across macOS and Linux: Trash dir, octal mode, UUID, and open-file PID lookup.
agyx_trash_base() {
  _tb_home=${1:-$AGYX_HOME}
  if [ -n "${AGYX_TRASH_DIR-}" ]; then printf '%s' "$AGYX_TRASH_DIR"
  elif [ -d "$_tb_home/.Trash" ] || [ "$AGYX_OS" = Darwin ]; then printf '%s' "$_tb_home/.Trash"
  else
    case ${XDG_DATA_HOME-} in /*) printf '%s/Trash/files' "$XDG_DATA_HOME" ;; *) printf '%s/.local/share/Trash/files' "$_tb_home" ;; esac
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

# Open PIDs holding non-symlink private targets inside one or more profile app directories.
agyx_profile_pids() (
  _n=$#
  while [ "$_n" -gt 0 ]; do
    _d=$1; shift; _n=$((_n - 1))
    [ -d "$_d" ] && [ ! -L "$_d" ] || continue
    set -- "$@" "$_d"
    if [ -e "$_d/conversation_summaries.db" ] && [ ! -L "$_d/conversation_summaries.db" ]; then
      set -- "$@" "$_d/conversation_summaries.db"
    fi
    for _lg in "$_d"/log/*.log; do
      [ -f "$_lg" ] && [ ! -L "$_lg" ] && set -- "$@" "$_lg"
    done
    for _dm in "$_d"/daemon/*; do
      [ -e "$_dm" ] && [ ! -L "$_dm" ] && set -- "$@" "$_dm"
    done
    for _pt in "$_d"/persistent_terminals/*; do
      [ -e "$_pt" ] && [ ! -L "$_pt" ] && set -- "$@" "$_pt"
    done
  done
  [ $# -gt 0 ] && agyx_open_pids "$@"
)

# Strict per-account regular files (token and atomic-rename state).
agyx_private_file() {
  case $1 in antigravity-oauth-token|settings.json|jetski_state.pbtxt|jetbox_summaries_proto.pb) return 0 ;; esac
  return 1
}

# All per-account entries (never linked from ~/.gemini/antigravity-cli):
# cache holds default_project_id.txt; daemon holds remote-control discovery/tokens; persistent_terminals holds per-profile PTY state; log + cli.log are managed & pruned by native agy per profile.
agyx_private() {
  agyx_private_file "$1" && return 0
  case $1 in cache|crashes|daemon|log|cli.log|persistent_terminals|updater|last_check.timestamp) return 0 ;; esac
  return 1
}

agyx_sidecar() {
  case $1 in *-wal|*-shm|*-journal) return 0 ;; esac
  return 1
}

agyx_is_known_shared() {
  case " $AGYX_SHARED_DIRS $AGYX_SHARED_FILES " in *" ${1-} "*) return 0 ;; esac
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
  _shared=${1:-$AGYX_HOME/.gemini/antigravity-cli}
  for _dir in "$AGYX_DATA"/profiles/*; do
    [ -d "$_dir/antigravity-cli" ] && [ ! -L "$_dir" ] && [ ! -L "$_dir/antigravity-cli" ] || continue
    for _entry in "$_dir/antigravity-cli"/* "$_dir/antigravity-cli"/.[!.]* "$_dir/antigravity-cli"/..?*; do
      [ ! -L "$_entry" ] && [ -e "$_entry" ] || continue
      _name=${_entry##*/}
      agyx_private "$_name" && continue
      agyx_sidecar "$_name" && continue
      agyx_is_known_shared "$_name" && return 0
      [ ! -e "$_shared/$_name" ] && [ ! -L "$_shared/$_name" ] || return 0
      for _other in "$AGYX_DATA"/profiles/*; do
        [ "$_other" != "$_dir" ] && [ ! -L "$_other" ] && [ ! -L "$_other/antigravity-cli" ] || continue
        [ ! -e "$_other/antigravity-cli/$_name" ] || [ -L "$_other/antigravity-cli/$_name" ] || return 0
      done
    done
  done
  return 1
)

# True when $1 (<profile_app_dir>) and $2 (<shared_dir>) already match in steady state (zero forks, lock-free fast path).
agyx_is_synced() {
  _pdir=$1 _shared=$2
  [ -d "$_pdir" ] && [ -d "$_shared" ] || return 1
  # shellcheck disable=SC2086 # fixed space-separated names in AGYX_SHARED_*
  for _n in $AGYX_SHARED_DIRS $AGYX_SHARED_FILES; do
    [ -e "$_shared/$_n" ] && [ -L "$_pdir/$_n" ] || return 1
  done
  for _s in "$_shared"/* "$_shared"/.[!.]* "$_shared"/..?*; do
    [ -e "$_s" ] || [ -L "$_s" ] || continue
    _n=${_s##*/}
    agyx_sidecar "$_n" && continue
    agyx_private "$_n" && continue
    [ -e "$_pdir/$_n" ] || [ -L "$_pdir/$_n" ] || return 1
  done
  for _p in "$_pdir"/* "$_pdir"/.[!.]* "$_pdir"/..?*; do
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
  _shared=$1
  _pids=$(
    {
      agyx_open_pids "$_shared/conversation_summaries.db"
      agyx_profile_pids "$AGYX_DATA"/profiles/*/antigravity-cli
    } | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -u | tr '\n' ' '
  )
  [ -z "$_pids" ] || { echo "agyx: close agy before shared repair (PIDs: ${_pids% }); nothing repaired" >&2; return 1; }
  _tbase=$(agyx_trash_base)
  mkdir -p "$_tbase" || return 1
  _trash=$(mktemp -d "$_tbase/agyx-shared-repair-XXXXXX") || return 1
  for _dir in "$AGYX_DATA"/profiles/*; do
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

# Steady-state launches pass through lock-free with zero forks; mutations serialize under $AGYX_DATA/.lock.
agyx_sync_app() (
  _pdir=$1
  umask 077
  _shared=$AGYX_HOME/.gemini/antigravity-cli _consented=0
  if agyx_needs_repair "$_shared"; then
    agyx_confirm_repair || return $?
    _consented=1
  elif [ ! -e "$AGYX_DATA/.lock" ] && agyx_is_synced "$_pdir" "$_shared"; then
    return 0
  fi
  mkdir -p "$_pdir" "$_shared" || return 1
  _lock=$AGYX_DATA/.lock _tries=${AGYX_LOCK_TRIES:-250}
  # ponytail: global spin-wait lock (up to ~5s); steady state skips this via agyx_is_synced above
  while ! mkdir "$_lock" 2>/dev/null; do
    _tries=$((_tries - 1))
    [ "$_tries" -gt 0 ] || { echo "agyx: shared preparation is busy; if no agyx is preparing, remove stale lock with: rmdir $_lock" >&2; return 1; }
    sleep 0.02
  done
  trap 'rmdir "$_lock"' EXIT
  trap 'exit 1' HUP INT TERM
  if agyx_needs_repair "$_shared"; then
    [ "$_consented" = 1 ] || [ "${AGYX_ASSUME_YES-}" = 1 ] || {
      echo "agyx: shared entries changed concurrently; run again to confirm repair" >&2
      return 1
    }
    agyx_do_repair "$_shared" || return 1
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
    [ -e "$_pdir/$_n" ] || [ -L "$_pdir/$_n" ] || ln -s "$_s" "$_pdir/$_n" || return 1
  done
  for _p in "$_pdir"/* "$_pdir"/.[!.]* "$_pdir"/..?*; do
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
  _from=$(cd "$AGYX_HOME/.gemini" && pwd -P) || return 1
  _to=$(cd "$1" && pwd -P) || return 1
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
  _pdir=$1 _shared=$AGYX_HOME/.gemini/antigravity-cli
  _rline=${AGYX_DOC_LINE:-echo} _rwarn=${AGYX_DOC_WARN:-echo}
  for _p in "$_pdir"/* "$_pdir"/.[!.]* "$_pdir"/..?*; do
    [ -e "$_p" ] || [ -L "$_p" ] || continue
    _n=${_p##*/}
    agyx_sidecar "$_n" && continue
    if agyx_private_file "$_n"; then
      [ ! -L "$_p" ] && [ -f "$_p" ] || "$_rwarn" "  antigravity-cli $_n: WARNING private entry is not a regular file"
    elif agyx_private "$_n"; then
      if [ -L "$_p" ] && [ "$(readlink "$_p")" = "$_shared/$_n" ]; then
        "$_rline" "  antigravity-cli $_n: shared link (detached on next launch)"
      fi
    elif [ -L "$_p" ] && [ "$(readlink "$_p")" = "$_shared/$_n" ] && [ -e "$_p" ]; then
      "$_rline" "  antigravity-cli $_n: linked"
    elif [ -L "$_p" ]; then "$_rwarn" "  antigravity-cli $_n: WARNING broken or unexpected link"
    elif [ -e "$_shared/$_n" ] || [ -L "$_shared/$_n" ]; then "$_rwarn" "  antigravity-cli $_n: DRIFT (present on both sides; left untouched)"
    else "$_rline" "  antigravity-cli $_n: local (adopted on next launch)"; fi
  done
  for _s in "$_shared"/* "$_shared"/.[!.]* "$_shared"/..?*; do
    [ -e "$_s" ] || [ -L "$_s" ] || continue
    _n=${_s##*/}
    agyx_sidecar "$_n" && continue
    agyx_private "$_n" && continue
    [ -e "$_pdir/$_n" ] || [ -L "$_pdir/$_n" ] || "$_rline" "  antigravity-cli $_n: missing link (linked on next launch)"
  done
}

# Email comes only from this login's log, never from its token or another profile's logs.
agyx_email_file() {
  [ -f "$1" ] || return 0
  _el=$(grep applyAuthResult "$1" 2>/dev/null | sed -n 's/.*email=\([^][ ,;"}()]*\).*/\1/p' | tail -n 1 | tr -d '[:cntrl:]')
  case $_el in *[[:space:]]*) ;; *) printf '%s' "$_el" ;; esac
}

# A future agy may ignore AGY_CLI_FORCE_FILE_TOKEN_STORAGE and fall back to keychain-first, mixing accounts.
agyx_check_storage() {
  case $1 in /*) _storage_log=$1 ;; *) _storage_log=$PWD/$1 ;; esac
  if ! grep -Fq 'Using file-based token storage' "$_storage_log" 2>/dev/null; then
    echo "agyx: WARNING: file-based token storage NOT confirmed in $1. Stop using profiles until agy compatibility is checked: keychain fallback can mix accounts and delete the profile token file." >&2
    return 1
  fi
}

# Doctor-only static check on native agy binary (requires agy >= 1.5.16; no cache files written to disk).
agyx_check_binary() {
  if ! LC_ALL=C grep -Fq AGY_CLI_FORCE_FILE_TOKEN_STORAGE "$1" 2>/dev/null ||
     ! LC_ALL=C grep -Fq app_data_dir "$1" 2>/dev/null ||
     ! LC_ALL=C grep -Fq 'Using file-based token storage' "$1" 2>/dev/null; then
    echo "agyx: WARNING: file-based token storage markers NOT confirmed in $1 (agy >= 1.5.16 required; run: agy update). Stop using profiles until agy compatibility is checked: keychain fallback can mix accounts and delete the profile token file." >&2
    return 1
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
  AGYX_RESOLVED=$1 _hops=0
  while [ -L "$AGYX_RESOLVED" ]; do
    _hops=$((_hops + 1)); [ "$_hops" -le 40 ] || return 1
    _link=$(readlink "$AGYX_RESOLVED") || return 1
    case $_link in
      /*) AGYX_RESOLVED=$_link ;;
      *) case $AGYX_RESOLVED in */*) AGYX_RESOLVED=${AGYX_RESOLVED%/*}/$_link ;; *) AGYX_RESOLVED=$_link ;; esac ;;
    esac
  done
  case $AGYX_RESOLVED in */*) _rdir=${AGYX_RESOLVED%/*}; _rbase=${AGYX_RESOLVED##*/} ;; *) _rdir=.; _rbase=$AGYX_RESOLVED ;; esac
  _parent=$(cd "${_rdir:-/}" && pwd -P) || return 1
  AGYX_RESOLVED=${_parent%/}/$_rbase
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
  agyx_is_shim "$AGYX_RESOLVED" && return 1
  AGYX_REAL=$AGYX_RESOLVED
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
  agyx_real_candidate "$AGYX_HOME/.local/bin/agy"
}

# Only links to agyx code (including removed Homebrew versions) belong to us.
agyx_own_link() {
  [ -L "$1" ] || return 1
  _link=$(readlink "$1") || return 1
  case $_link in
    */Cellar/agyx/*/libexec/bin/agy|*/Cellar/agyx-beta/*/libexec/bin/agy|*/opt/agyx/libexec/bin/agy|*/opt/agyx-beta/libexec/bin/agy) return 0 ;;
  esac
  agyx_resolve_path "$1" 2>/dev/null && agyx_is_shim "$AGYX_RESOLVED"
}

# <data>/agy is the only app entry. Preserve unrelated files/links at that path.
agyx_ensure_entry() {
  [ "$AGYX_DATA/agy" -ef "$AGYX_SHIM" ] && return 0
  if [ -e "$AGYX_DATA/agy" ] || [ -L "$AGYX_DATA/agy" ]; then agyx_own_link "$AGYX_DATA/agy" || return 0; fi
  (umask 077; mkdir -p "$AGYX_DATA") && ln -sfn "$AGYX_SHIM" "$AGYX_DATA/agy"
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
    "$AGYX_HOME") printf '~' ;;
    "$AGYX_HOME"/*) printf '~/%s' "${1#"$AGYX_HOME"/}" ;;
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
  [ -d "$AGYX_DATA" ] && return 0
  agyx_find_real || agyx_missing_agy
  if [ "${AGYX_ASSUME_YES-}" != 1 ]; then
    agyx_has_tty || { echo "agyx: agyx is not set up yet. Run agyx once in a terminal to set it up (or set AGYX_ASSUME_YES=1)." >&2; exit 5; }
    {
      echo "agyx will set up:"
      echo "  $(agyx_tilde "$AGYX_DATA")/  profiles (private app settings and file login per account)"
      echo "  $(agyx_tilde "$AGYX_DATA")/agy  entry for apps that need a binary named agy"
      echo "Profiles use your real HOME and share conversations and history; your system keyring is not touched."
    } >&2
    agyx_ask y 'Continue? [Y/n] ' || { echo >&2; die "not set up; nothing was written."; }
  fi
  (umask 077; mkdir -p "$AGYX_DATA") || die "cannot create $AGYX_DATA"
}
