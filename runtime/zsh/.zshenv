# agyx bridge: restore the real environment, then load the user's own .zshenv.
[ -n "${AGYX_REAL_HOME-}" ] && { HOME=$AGYX_REAL_HOME; export HOME; }
if [ "${AGYX_ORIG_ZDOTDIR_SET-}" = 1 ]; then ZDOTDIR=$AGYX_ORIG_ZDOTDIR; export ZDOTDIR; else unset ZDOTDIR; fi
if [ "${AGYX_ORIG_BASH_ENV_SET-}" = 1 ]; then BASH_ENV=$AGYX_ORIG_BASH_ENV; export BASH_ENV; else unset BASH_ENV; fi
if [ -r "${ZDOTDIR:-$HOME}/.zshenv" ]; then . "${ZDOTDIR:-$HOME}/.zshenv"; fi
