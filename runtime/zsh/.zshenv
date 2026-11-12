# agyctl bridge: restore the real environment, then load the user's own .zshenv.
[ -n "${AGYCTL_REAL_HOME-}" ] && { HOME=$AGYCTL_REAL_HOME; export HOME; }
if [ "${AGYCTL_ORIG_ZDOTDIR_SET-}" = 1 ]; then ZDOTDIR=$AGYCTL_ORIG_ZDOTDIR; export ZDOTDIR; else unset ZDOTDIR; fi
if [ "${AGYCTL_ORIG_BASH_ENV_SET-}" = 1 ]; then BASH_ENV=$AGYCTL_ORIG_BASH_ENV; export BASH_ENV; else unset BASH_ENV; fi
if [ -r "${ZDOTDIR:-$HOME}/.zshenv" ]; then . "${ZDOTDIR:-$HOME}/.zshenv"; fi
