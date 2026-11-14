# shellcheck shell=sh
# shellcheck disable=SC2154,SC2034 # R, P, data, AGYX_SHIM and AGYX_RUNTIME are set by callers
# R = real HOME; P = profile app directory. Never read or copy a token.
AGYX_VERSION=0.2.0-beta.5 # the one place the version lives (the formula's url tag must match)

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

agyx_legacy() {
  command -v agyx_do_remove_blocker >/dev/null 2>&1 && return 0
  # shellcheck source=legacy.sh
  . "${AGYX_RUNTIME:-${here:+$here/runtime}}/legacy.sh"
}

agyx_remove_blocker() { agyx_legacy && agyx_do_remove_blocker; }

agyx_migrate() {
  for _d in "$data"/profiles/*; do
    if [ -d "$_d/home" ] || [ -L "$_d/home" ]; then agyx_legacy && agyx_run_migrate; return; fi
  done
}

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
    return 1
  }
  {
    echo "agyx will repair shared entries for all profiles. Close all agy sessions first."
    echo "Directory conflicts: newer wins (shared wins ties); the other copy goes to the Trash."
    echo "History: append missing lines. Shared DB/other files stay; profile copies go to the Trash."
    echo "The four private files are never touched."
  } >&2
  agyx_ask y 'Continue? [Y/n] ' || { echo "agyx: shared repair cancelled; nothing repaired" >&2; return 1; }
}

agyx_do_repair() (
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

# Serialize preparation/repair, not prompts or native agy sessions.
agyx_sync_app() (
  umask 077
  _shared=$R/.gemini/antigravity-cli _consented=0
  if agyx_needs_repair; then
    agyx_confirm_repair || return 1
    _consented=1
  fi
  mkdir -p "$P" "$_shared" || return 1
  _lock=$data/.lock _tries=${AGYX_LOCK_TRIES:-100}
  # ponytail: global spin-wait lock (up to ~5s); switch to flock/shlock only if launch concurrency outgrows this
  while ! mkdir "$_lock" 2>/dev/null; do
    _tries=$((_tries - 1))
    [ "$_tries" -gt 0 ] || { echo "agyx: shared preparation is busy; if no agyx is preparing, remove stale lock with: rmdir $_lock" >&2; return 1; }
    sleep 0.05
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

# A future agy may ignore WSL and fall back to keychain-first, mixing accounts.
agyx_check_storage() {
  case $1 in /*) _storage_log=$1 ;; *) _storage_log=$PWD/$1 ;; esac
  if ! grep -Fq 'Using file-based token storage' "$_storage_log" 2>/dev/null; then
    echo "agyx: WARNING: file-based token storage NOT confirmed in $1. Stop using profiles until agy compatibility is checked: keychain fallback can mix accounts and delete the profile token file." >&2
  fi
}

# Pre-exec binary marker check (cached by stat stamp) so bin/agy can exec native agy directly.
agyx_check_binary() {
  _stamp=$(stat -f '%d:%i:%m:%z' "$1" 2>/dev/null):$1
  if [ -f "$data/.verified" ]; then
    _saved=''
    IFS= read -r _saved < "$data/.verified" || :
    [ "$_saved" = "$_stamp" ] && return 0
  fi
  if LC_ALL=C grep -Fq WSL_DISTRO_NAME "$1" 2>/dev/null &&
     LC_ALL=C grep -Fq app_data_dir "$1" 2>/dev/null &&
     LC_ALL=C grep -Fq 'Using file-based token storage' "$1" 2>/dev/null; then
    (umask 077; printf '%s\n' "$_stamp" > "$data/.verified") 2>/dev/null || :
  else
    echo "agyx: WARNING: file-based token storage markers NOT confirmed in $1. Stop using profiles until agy compatibility is checked: keychain fallback can mix accounts and delete the profile token file." >&2
  fi
}

agyx_check_recent_log() {
  ls -t "$1"/log/*.log 2>/dev/null | while IFS= read -r _nl; do
    [ -s "$_nl" ] || continue
    agyx_check_storage "$_nl"
    break
  done
}

# Per-profile agy log: <profile dir>/log/cli-YYYYMMDD_HHMMSS.log, a new file per launch.
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

# <data>/agy is the only app entry. Preserve unrelated files/links at that path.
agyx_ensure_entry() {
  if [ -L "$data/real-agy" ] || [ -d "$data/bin" ]; then
    agyx_legacy && agyx_clean_old_entry || return 1
  fi
  [ "$data/agy" -ef "$AGYX_SHIM" ] && return 0
  if [ -e "$data/agy" ] || [ -L "$data/agy" ]; then agyx_own_link "$data/agy" || return 0; fi
  (umask 077; mkdir -p "$data") && ln -sfn "$AGYX_SHIM" "$data/agy"
}

# Map Homebrew's versioned Cellar path to <prefix>/opt/<formula>/... when it exists.
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
    agyx_has_tty || die "agyx is not set up yet. Run agyx once in a terminal to set it up (or set AGYX_ASSUME_YES=1)."
    {
      echo "agyx will set up:"
      echo "  $(agyx_tilde "$data")/  profiles (private app settings and file login per account)"
      echo "  $(agyx_tilde "$data")/agy  entry for apps that need a binary named agy"
      echo "Profiles use your real HOME and share conversations and history; your login keychain is not touched."
    } >&2
    agyx_ask y 'Continue? [Y/n] ' || { echo >&2; die "not set up; nothing was written."; }
  fi
  (umask 077; mkdir -p "$data") || die "cannot create $data"
}
