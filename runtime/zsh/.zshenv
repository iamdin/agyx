# agyx bridge: remove our desktop keyring-bypass marker, then load the user's own .zshenv.
if [ -n "${AGYX_ORIG_WSL_INTEROP-}" ]; then WSL_INTEROP=${AGYX_ORIG_WSL_INTEROP#:}; export WSL_INTEROP; else unset WSL_INTEROP; fi
if [ -n "${AGYX_ORIG_ZDOTDIR-}" ]; then ZDOTDIR=${AGYX_ORIG_ZDOTDIR#:}; export ZDOTDIR; else unset ZDOTDIR; fi
if [ -n "${AGYX_ORIG_BASH_ENV-}" ]; then BASH_ENV=${AGYX_ORIG_BASH_ENV#:}; export BASH_ENV; else unset BASH_ENV; fi
# shellcheck disable=SC3045 # Zsh pattern unset; no variable values are evaluated.
unset -m 'AGYX_ORIG_*'
unset AGYX_REAL_HOME AGY_PROFILE
if [ -r "${ZDOTDIR:-$HOME}/.zshenv" ]; then . "${ZDOTDIR:-$HOME}/.zshenv"; fi
