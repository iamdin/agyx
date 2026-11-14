# shellcheck shell=sh
# shellcheck disable=SC2154 # R, data and AGYX_SHIM are set by callers
# Transitional 0.1.x / 0.2.0-beta migration and obsolete layout cleanup.

agyx_set_links_file() {
  case ${XDG_CONFIG_HOME-} in
    /*) AGYX_LINKS_FILE=$XDG_CONFIG_HOME/agyx/symlinks ;;
    *) AGYX_LINKS_FILE=$R/.config/agyx/symlinks ;;
  esac
}

# Only remove the exact blocker created by 0.1.3, never plain agy's file or an unknown directory.
agyx_do_remove_blocker() {
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

agyx_run_migrate() {
  for _d in "$data"/profiles/*; do
    [ -d "$_d/home" ] || [ -L "$_d/home" ] || continue
    [ ! -L "$_d" ] && [ ! -L "$_d/home" ] && [ -d "$_d/home" ] || die "unsafe legacy profile: $_d"
  done
  if [ "${AGYX_ASSUME_YES-}" != 1 ]; then
    agyx_has_tty || die "old profiles need migration; run once in a terminal (or set AGYX_ASSUME_YES=1); nothing changed"
    {
      echo "agyx will migrate all old profiles to real HOME and private file logins."
      echo "Each profile must sign in again. Old profile keychains will be deleted; home/ goes to the Trash."
      echo "Email stays; old logs, whitelist and the agyx token blocker are cleaned up."
    } >&2
    agyx_ask y 'Continue? [Y/n] ' || die "migration cancelled; nothing changed"
  fi
  set -- "$data/real-agy" "$data/bin/agy"
  for _d in "$data"/profiles/*; do
    [ -d "$_d/home" ] || continue
    set -- "$@" "$_d/home/Library/Keychains/login.keychain-db"
  done
  _pids=$(/usr/sbin/lsof -nP -t "$@" 2>/dev/null | sort -u | tr '\n' ' ')
  [ -z "$_pids" ] || die "close agy before migration (PIDs: ${_pids% }); nothing changed"
  (umask 077; mkdir -p "${AGYX_TRASH_DIR:-$R/.Trash}") || die "cannot create Trash directory"
  _trash=$(mktemp -d "${AGYX_TRASH_DIR:-$R/.Trash}/agyx-migrate-$(date +%Y%m%d%H%M%S)-XXXXXX") || die "cannot create migration Trash directory"
  # Delete keychains before moving homes, using each old HOME and explicit keychain path only.
  for _d in "$data"/profiles/*; do
    [ -d "$_d/home" ] || continue
    agyx_delete_old_keychain "$_d"
    mkdir -p "$_trash/${_d##*/}" || die "cannot prepare migration Trash directory"
    mv "$_d/home" "$_trash/${_d##*/}/home" || die "cannot move old profile home to the Trash"
    [ ! -d "$_d/log" ] || [ -L "$_d/log" ] || mv "$_d/log" "$_trash/${_d##*/}/log" || die "cannot move old profile logs to the Trash"
    (umask 077; mkdir -p "$_d/antigravity-cli") || die "cannot create profile app directory"
    echo "agyx: profile ${_d##*/}: old home moved to $_trash/${_d##*/}/home; sign in again with agyx profile login ${_d##*/}" >&2
  done
  agyx_do_remove_blocker || die "cannot remove old token blocker"
  agyx_set_links_file
  [ ! -f "$AGYX_LINKS_FILE" ] || mv "$AGYX_LINKS_FILE" "$_trash/symlinks" || die "cannot move old whitelist to the Trash"
}

agyx_clean_old_entry() {
  rm -f "$data/.verified" "$data/.verified-agy"
  if [ -L "$data/real-agy" ]; then
    case $(readlink "$data/real-agy") in /*/agy) rm "$data/real-agy" || return 1 ;; esac
  fi
  _entry_trash=''
  if [ -d "$data/bin" ] && [ ! -L "$data/bin" ] && agyx_own_link "$data/bin/agy"; then
    (umask 077; mkdir -p "${AGYX_TRASH_DIR:-$R/.Trash}") || return 1
    _entry_trash=$(mktemp -d "${AGYX_TRASH_DIR:-$R/.Trash}/agyx-entry-layout-XXXXXX") || return 1
    mv "$data/bin/agy" "$_entry_trash/agy" || return 1
    [ -z "$(find "$data/bin" -prune -empty -print)" ] || mv "$data/bin" "$_entry_trash/bin" || return 1
  fi
  for _d in "$data"/profiles/*; do
    [ -d "$_d/log" ] && [ ! -L "$_d/log" ] && [ ! -L "$_d" ] || continue
    if [ -z "$_entry_trash" ]; then
      (umask 077; mkdir -p "${AGYX_TRASH_DIR:-$R/.Trash}") || return 1
      _entry_trash=$(mktemp -d "${AGYX_TRASH_DIR:-$R/.Trash}/agyx-entry-layout-XXXXXX") || return 1
    fi
    mkdir -p "$_entry_trash/logs" || return 1
    mv "$_d/log" "$_entry_trash/logs/${_d##*/}" || return 1
  done
}
