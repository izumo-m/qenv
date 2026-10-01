# qenv -- quarantined env manager
#
# A direnv-like manager that quarantines environment variables outside your
# repositories, under ~/.config/qenv. Source it from .bashrc (or similar) and register the
# trigger:
#
#     source /path/to/qenv.sh
#     PROMPT_COMMAND=qenv
#
# See README.md for usage, docs/spec.md for the design. Requires bash 5.x (4.x at the very least).

if ((BASH_VERSINFO[0] < 4)); then
  printf 'qenv: requires bash 4+ (associative arrays, declare -g)\n' >&2
  return 1 2>/dev/null || exit 1
fi

#### Dispatcher ##############################################################

qenv() {
  local __ret=$?                               # save the previous command's $? (see below)
  # Re-entry guard: if a source during enter/leave, or qenv-leave, calls qenv back, do nothing
  # (e.g. something inside qenv.enter calls eval "$PROMPT_COMMAND"). The flag is local, so dynamic
  # scoping shows it only to callees, and it unwinds even on ^C (a global would stay set forever).
  [[ -n ${_QENV_BUSY:-} ]] && return $__ret
  local _QENV_BUSY=1
  # If enter is interrupted by ^C, the exec-detection marker _QENV_ENTERING may be left behind.
  # This is top level (during enter we would have returned at the guard above), so clean it up.
  [[ -n ${_QENV_ENTERING:-} ]] && unset -v _QENV_ENTERING
  (( $# )) || {                                  # no args = the sync body (via PROMPT_COMMAND). $? is passed through
    [[ -n ${_QENV_DISABLED:-} ]] && return $__ret    # while disabled, cd does nothing (state is left as is)
    _qenv_edit_pending; _qenv_sync; return $__ret
  }
  case $1 in
    status)          _qenv_status ;;
    edit)            _qenv_edit "${2:-.}" ;;
    enable)          _qenv_enable ;;
    disable)         _qenv_disable ;;
    reload)          _qenv_reload_now ;;
    help|-h|--help)  _qenv_help ;;
    *) printf 'qenv: unknown command: %s\n' "$1" >&2; _qenv_help >&2; return 2 ;;
  esac
}

#### Sync: align with the qenv.enter that applies to cwd #####################

_qenv_sync() {
  [[ $PWD == "$_QENV_PREV_PWD" ]] && return     # PWD unchanged: return at once (most prompts end here)
  _QENV_PREV_PWD=$PWD
  local dir; dir=$(pwd -P)                       # realpath normalization (only when PWD changed)
  _qenv_find "$dir"                             # -> _QENV_FOUND_ENTER
  [[ $_QENV_FOUND_ENTER == "$_QENV_ACTIVE_ENTER" ]] && return  # the same qenv.enter applies: nothing to do
  [[ -n $_QENV_ACTIVE_ENTER ]] && _qenv_leave    # leave the old qenv.enter
  if [[ -z $_QENV_FOUND_ENTER ]]; then
    _QENV_ACTIVE_ENTER=
  elif [[ $_QENV_FOUND_ENTER == "$_QENV_SKIP_ENTER" ]]; then
    _QENV_ACTIVE_ENTER=                          # exec loop guard (see the detection at load time). Not recorded as entered either
    _qenv_pretty "$_QENV_FOUND_ENTER"
    _qenv_notify "enter suppressed (exec loop guard): $_QENV_PRETTY"
  else
    _qenv_enter "$_QENV_FOUND_ENTER"
    _QENV_ACTIVE_ENTER=$_QENV_FOUND_ENTER
  fi
}

#### Find: walk up from cwd to / #############################################

_qenv_find() {                # $1 = normalized directory. The result goes to _QENV_FOUND_ENTER
  local dir=$1 f
  while :; do
    f="$QENV_ROOT${dir%/}/qenv.enter"           # ${dir%/} avoids // when dir is /
    [[ -e $f ]] && { _QENV_FOUND_ENTER=$f; return 0; }
    [[ $dir == / ]] && { _QENV_FOUND_ENTER=; return 1; }   # stop after walking all the way up to /
    dir=${dir%/*}; [[ -z $dir ]] && dir=/
  done
}

#### enter: load the environment variables ###################################

_qenv_enter() {               # $1 = path to qenv.enter
  local enter=$1
  unset -f qenv-leave         # drop the qenv-leave defined by the previous qenv.enter
  _qenv_diff_capture          # capture the exports before source as the baseline
  # Marker for exec detection, set only while sourcing. If qenv.enter (or something it calls) execs
  # or starts a shell, the whole environment is inherited as it stands before enter completes, and the new shell
  # detects it when it loads qenv.sh (see the bottom of this file).
  export _QENV_ENTERING=$enter
  set --                      # an argument-less source inherits the caller's $@, so empty it
  _qenv_pretty "$enter"       # print before source: even if it hangs/execs/exits, the file is known (symmetric with leave)
  _qenv_notify "enter $_QENV_PRETTY"
  source "$enter"             # a plain source (no set -a)
  unset -v _QENV_ENTERING     # completed -> clear the marker (outside capture/compare, so it never appears in the diff)
  _qenv_diff_build            # build _qenv_restore from the baseline-vs-current diff
  hash -r                     # clear the command hash (in case PATH changed)
  if [[ $_QENV_SKIP_ENTER == "$enter" ]]; then   # it completed = no longer dangerous -> the suppression lifts itself
    _QENV_SKIP_ENTER=
  fi
}

#### leave: cleanup hook and rollback ########################################

_qenv_leave() {
  _qenv_pretty "$_QENV_ACTIVE_ENTER"
  _qenv_notify "leave $_QENV_PRETTY"
  declare -F qenv-leave >/dev/null && qenv-leave   # (1) the cleanup hook, if any. Before the rollback
  _qenv_restore 2>/dev/null                        # (2) always roll back
  unset -f qenv-leave _qenv_restore 2>/dev/null    # tidy up
  hash -r
}

#### Rollback: capture the baseline, build the restore function ##############

# Both capture and build scan the single bulk output of declare -px. Using $(declare -p name) for each
# variable forks a command substitution once per variable and makes enter visibly slow (in bulk it
# forks once). declare -px prints one line per variable (newlines etc. in values are folded into
# $'...') in the same format as a per-name declare -p, so lines can be stored verbatim and compared
# as strings. Stripping the leading "declare -flags " gives the variable name.

_qenv_diff_capture() {        # record the current exports in _QENV_DIFF_BASE (not exported)
  declare -gA _QENV_DIFF_BASE=()
  local line name
  while IFS= read -r line; do
    name=${line#declare -* }; name=${name%%=*}
    _qenv_excluded "$name" && continue
    _QENV_DIFF_BASE[$name]=$line
  done < <(declare -px)
}

_qenv_diff_build() {          # define _qenv_restore from the baseline-vs-current diff
  local body= line name old
  local -A seen=()
  while IFS= read -r line; do                       # scan the variables currently exported
    name=${line#declare -* }; name=${name%%=*}
    _qenv_excluded "$name" && continue
    seen[$name]=1
    _qenv_kept "$name" && continue                   # matches QENV_KEEP -> do not roll back
    if [[ -z ${_QENV_DIFF_BASE[$name]+s} ]]; then
      body+="unset -v $name"$'\n'                    # newly exported -> unset
    elif [[ $line != "${_QENV_DIFF_BASE[$name]}" ]]; then
      old=${_QENV_DIFF_BASE[$name]}
      body+="declare -g${old#declare}"$'\n'          # value changed -> back to the old value (add -g to the output)
    fi
  done < <(declare -px)
  for name in "${!_QENV_DIFF_BASE[@]}"; do           # in the baseline but gone now = unset/de-exported -> back to the old value
    [[ -n ${seen[$name]+s} ]] && continue
    _qenv_kept "$name" && continue                   # matches QENV_KEEP -> do not restore, even if it was unset
    old=${_QENV_DIFF_BASE[$name]}
    body+="declare -g${old#declare}"$'\n'
  done
  eval "_qenv_restore() { ${body}:; }"               # the trailing : prevents an empty body
  unset _QENV_DIFF_BASE
}

_qenv_excluded() { case $1 in PWD|OLDPWD|SHLVL|_) return 0 ;; *) return 1 ;; esac; }

_qenv_kept() {                # 0 if $1 matches QENV_KEEP (whitespace-separated, globs allowed)
  [[ -n ${QENV_KEEP:-} ]] || return 1
  local -a pats; local pat
  read -ra pats <<< "$QENV_KEEP"                     # read -ra: split without pathname expansion
  for pat in "${pats[@]}"; do
    [[ $1 == $pat ]] && return 0
  done
  return 1
}

#### Notification ############################################################

_qenv_notify() { [[ -n ${QENV_QUIET:-} ]] || printf 'qenv: %s\n' "$1" >&2; }

# Display formatting for paths: shorten a leading $HOME/ to ~/ and return it in _QENV_PRETTY
# (avoids forking a command substitution). Display only; never used for real path handling
# (find, source, mtime, and so on).
_qenv_pretty() {              # $1 = path
  local home=${HOME:-}; home=${home%/}            # tolerate a trailing /; safe under set -u even if HOME is unset
  if [[ $home == /?* && $1 == "$home"/* ]]; then  # /?* : do not shorten if HOME is / itself or empty
    _QENV_PRETTY="~${1#"$home"}"
  else
    _QENV_PRETTY=$1
  fi
}

#### Subcommands #############################################################

_qenv_status() {
  [[ -n ${_QENV_DISABLED:-} ]] && printf 'state:      disabled\n'   # shown only while disabled (omitted by default)
  if [[ -n $_QENV_ACTIVE_ENTER ]]; then
    _qenv_pretty "$_QENV_ACTIVE_ENTER"
    printf 'active:     %s\n' "$_QENV_PRETTY"
    if declare -F qenv-leave >/dev/null; then
      printf 'qenv-leave: defined\n'
    else
      printf 'qenv-leave: none\n'
    fi
  else
    printf 'active:     (none)\n'
  fi
  if ((${#_QENV_EDIT_PIDS[@]})); then                # edits deferred by ^Z, if any
    local t
    for t in "${_QENV_EDIT_TARGETS[@]}"; do
      _qenv_pretty "$t"
      printf 'edit wait:  %s\n' "$_QENV_PRETTY"
    done
  fi
  if [[ -n $_QENV_SKIP_ENTER ]]; then                # suppressed by the exec loop guard, if any
    _qenv_pretty "$_QENV_SKIP_ENTER"
    printf 'suppressed: %s (exec loop guard)\n' "$_QENV_PRETTY"
  fi
}

#### enable / disable / reload ###############################################

_qenv_disable() {             # a safe mode that stops syncing and reads no qenv.enter at all. The current env is left as is
  [[ -n ${_QENV_DISABLED:-} ]] && { _qenv_notify "already disabled"; return; }
  _QENV_DISABLED=1
  _qenv_notify "disabled (no enter/leave/reload; current env frozen -- 'qenv enable' to resume)"
}

_qenv_enable() {              # resume syncing, re-check where we are, and leave/enter if it differs
  _QENV_DISABLED=
  _qenv_notify "enabled"
  _QENV_PREV_PWD=             # force a re-check even if PWD is unchanged (defeats the early return in _qenv_sync)
  _qenv_sync                  # leave/enter if the applicable qenv.enter differs from the active one; otherwise nothing
}

_qenv_reload_now() {          # force the nearest qenv.enter to be re-read with leave->enter (an explicit action)
  # While disabled, read no qenv.enter and do not leave (this breaks the chain where re-reading a
  # broken enter damages the environment further). Recover in this order: fix -> qenv enable -> qenv reload.
  [[ -n ${_QENV_DISABLED:-} ]] && { _qenv_notify "disabled: nothing reloaded (run 'qenv enable' first)"; return 0; }
  local dir; dir=$(pwd -P)
  _qenv_find "$dir"                              # -> _QENV_FOUND_ENTER
  [[ -n $_QENV_ACTIVE_ENTER ]] && _qenv_leave    # always roll back if something is active
  if [[ -n $_QENV_FOUND_ENTER ]]; then
    _qenv_enter "$_QENV_FOUND_ENTER"             # the exec loop guard is bypassed (a completed enter lifts _QENV_SKIP_ENTER anyway)
    _QENV_ACTIVE_ENTER=$_QENV_FOUND_ENTER
  else
    _QENV_ACTIVE_ENTER=                          # nothing applies: only clear active
  fi
  _QENV_PREV_PWD=$PWD
}

_qenv_mtime() { [[ -e $1 ]] && stat -c %.Y "$1" 2>/dev/null; }  # GNU stat. Nanosecond precision (%Y would miss a save within the same second). Empty if the file is absent

_qenv_reload() {              # $1 = the edited qenv.enter. Re-read it if it is the nearest one for where we are
  # While disabled, do not apply it (qenv edit can still save, but no source/leave happens). Apply it after enabling.
  [[ -n ${_QENV_DISABLED:-} ]] && { _qenv_notify "disabled: saved but not applied (run 'qenv enable' then 'qenv reload')"; return 0; }
  local dir; dir=$(pwd -P)
  _qenv_find "$dir"
  [[ $_QENV_FOUND_ENTER == "$1" ]] || return 0       # the edited file does not apply where we are: do nothing
  [[ -n $_QENV_ACTIVE_ENTER ]] && _qenv_leave        # roll back first when re-reading the active one
  _qenv_enter "$_QENV_FOUND_ENTER"
  _QENV_ACTIVE_ENTER=$_QENV_FOUND_ENTER
}

_qenv_edit() {                # $1 = target directory (default .)
  local dir target ans before after rc pid
  dir=$(cd -- "$1" 2>/dev/null && pwd -P) || {
    printf 'qenv: no such directory: %s\n' "$1" >&2; return 1
  }
  target="$QENV_ROOT${dir%/}/qenv.enter"
  if [[ ! -e $target ]]; then                        # confirm before creating a new file (default No)
    _qenv_pretty "$target"
    read -r -p "qenv: create $_QENV_PRETTY? [y/N] " ans
    [[ ${ans,,} == y || ${ans,,} == yes ]] || { printf 'qenv: aborted\n' >&2; return 1; }
  fi
  before=$(_qenv_mtime "$target")                    # mtime before editing (empty if new)
  # EDITOR is expanded unquoted, so editors with arguments such as EDITOR="code --wait" work (the
  # usual convention, as in git). New files are created under umask 077, so 0600/0700. The leading
  # ": qenv-edit" is a no-op marker that stays in the job text (paired with the %+ match below;
  # change both if you change the wording).
  ( : qenv-edit; umask 077; mkdir -p "${target%/*}" && ${EDITOR:-vi} "$target" )
  rc=$?
  # On ^Z and friends (128+STOP/TSTP/TTIN/TTOU = 147-150) only the subshell stops, while this
  # function carries on. Looking at the mtime here is too early (nothing is saved yet), so applying
  # the change is deferred until the editor exits (checked at every prompt). Whether %+ (the job
  # that just stopped) really is the subshell above is confirmed with the marker -- otherwise an editor
  # that merely happened to exit with 147-150 would make us latch onto an unrelated job and defer wrongly.
  if (( rc >= 147 && rc <= 150 )) && [[ $(jobs %+ 2>/dev/null) == *': qenv-edit;'* ]]; then
    pid=$(jobs -p %+ 2>/dev/null)
    # The marker rejects unrelated jobs but not "another qenv-edit stopped earlier". If the PID of %+ is
    # already on the watch list, nothing stopped just now -- this was a plain 147-150 exit, so fall
    # through to the normal path (otherwise a saved edit would wait for the older editor to exit).
    if [[ -n $pid && " ${_QENV_EDIT_PIDS[*]} " != *" $pid "* ]]; then
      _QENV_EDIT_PIDS+=("$pid"); _QENV_EDIT_TARGETS+=("$target"); _QENV_EDIT_BEFORES+=("$before")
      _qenv_pretty "$target"
      _qenv_notify "editor stopped; reload deferred until it exits: $_QENV_PRETTY"
      return $rc
    fi
  fi
  after=$(_qenv_mtime "$target")                     # mtime after editing (empty if unsaved or never created)
  # Apply to the current shell only when it was actually saved (newly created, or the mtime advanced).
  [[ -n $after && $before != "$after" ]] && _qenv_reload "$target"
  return $rc
}

_qenv_edit_pending() {        # follow up on edits deferred by ^Z (every prompt; returns at once if none)
  ((${#_QENV_EDIT_PIDS[@]})) || return 0
  local -a pids=("${_QENV_EDIT_PIDS[@]}") targets=("${_QENV_EDIT_TARGETS[@]}") befores=("${_QENV_EDIT_BEFORES[@]}")
  local -A reloaded=()
  local i after
  # Take everything off the list first and put back only what stays. A reload performs an enter and
  # can re-enter qenv (a second line of defense alongside the dispatcher's _QENV_BUSY), so the list
  # is touched before the reload.
  _QENV_EDIT_PIDS=() _QENV_EDIT_TARGETS=() _QENV_EDIT_BEFORES=()
  for i in "${!pids[@]}"; do
    if kill -0 "${pids[i]}" 2>/dev/null && _qenv_is_job "${pids[i]}"; then
      _QENV_EDIT_PIDS+=("${pids[i]}")                # the editor is alive (including stopped) -> keep waiting
      _QENV_EDIT_TARGETS+=("${targets[i]}")
      _QENV_EDIT_BEFORES+=("${befores[i]}")
      continue
    fi
    after=$(_qenv_mtime "${targets[i]}")             # it exited -> apply the change if it was saved
    [[ -n $after && $after != "${befores[i]}" && -z ${reloaded["${targets[i]}"]+s} ]] || continue
    reloaded["${targets[i]}"]=1                      # reload only once, even if the same target was deferred several times
    _qenv_reload "${targets[i]}"
  done
  return 0
}

_qenv_is_job() {              # 0 if $1 is still in this shell's job table. With kill -0 alone we would
  local p                     # keep waiting if the PID were reused by another process after the editor died
  for p in $(jobs -p); do [[ $p == "$1" ]] && return 0; done
  return 1
}

_qenv_help() {
  cat <<'EOF'
qenv -- quarantined env manager

Usage:
  qenv               sync $PWD: enter/leave the nearest qenv.enter
                     (intended to be called from PROMPT_COMMAND)
  qenv status        show the active qenv.enter and qenv-leave state
  qenv edit [DIR]    edit DIR's qenv.enter with $EDITOR (default: .)
  qenv enable        resume syncing; re-check $PWD now (leave/enter on change)
  qenv disable       freeze: stop syncing AND skip enter/leave/reload (env kept)
  qenv reload        force leave then re-enter the nearest qenv.enter
                     (no-op while disabled; run 'qenv enable' first)
  qenv help          show this help

Setup (in ~/.bashrc, after sourcing qenv.sh):
  PROMPT_COMMAND=qenv

Inside a qenv.enter file:
  export NAME=value      environment variable (rolled back on leave)
  NAME=value             shell-local value (not exported, not rolled back)
  qenv-leave() { ...; }  runs on leave, before the rollback

Config:
  QENV_QUIET   non-empty: suppress enter/leave notifications
  QENV_KEEP    space-separated names/globs never rolled back
               (e.g. QENV_KEEP='KUBECONFIG AWS_*')
EOF
  _qenv_pretty "$QENV_ROOT"
  printf '\nConfig root (QENV_ROOT): %s\n' "$_QENV_PRETTY"
}

#### Initialization at load time #############################################

: "${QENV_ROOT:=${XDG_CONFIG_HOME:-$HOME/.config}/qenv}"   # default if unset
QENV_ROOT=${QENV_ROOT%/}                                    # normalize a trailing slash (avoids //)
[[ -d $QENV_ROOT ]] || { mkdir -p "$QENV_ROOT" && chmod 700 "$QENV_ROOT"; }  # create it with 700 if absent
: "${_QENV_PREV_PWD=}" "${_QENV_FOUND_ENTER=}" "${_QENV_ACTIVE_ENTER=}" "${_QENV_DISABLED=}"  # define empty (safe under set -u and on re-source; disable survives a re-source, while a new shell starts enabled)
# Exec loop guard: the marker set only while sourcing an enter (_QENV_ENTERING, exported) still
# being present at load time means this shell was exec'd or started while a qenv.enter was being
# processed. Auto-entering that same file could loop forever ("start -> enter -> start again"), so loading
# that one file is suppressed (e.g. an external command called by qenv.enter misdetects source vs.
# execution through a $0 collision and execs $SHELL). _QENV_BUSY covers re-entry within one shell;
# exec crosses processes without changing the PID, so only an environment marker can detect it.
# The suppression lifts itself once the file is fixed and enter completes (end of _qenv_enter).
: "${_QENV_SKIP_ENTER=}"
if [[ -n ${_QENV_ENTERING:-} ]]; then
  _QENV_SKIP_ENTER=$_QENV_ENTERING
  unset -v _QENV_ENTERING
  _qenv_pretty "$_QENV_SKIP_ENTER"
  printf 'qenv: this shell was started while entering %s\n' "$_QENV_PRETTY" >&2
  printf 'qenv: (exec or a new shell inside qenv.enter?) auto-enter of that file is suppressed to break a loop\n' >&2
fi
# Watch list for ^Z-deferred edits (parallel arrays). If they are already arrays, keep the pending
# entries across a re-source; otherwise define them as empty arrays (a declare -a with attributes
# only is unbound under set -u, so write the =() too).
case $(declare -p _QENV_EDIT_PIDS    2>/dev/null) in 'declare -a'*'=('*) ;; *) unset -v _QENV_EDIT_PIDS;    declare -ga _QENV_EDIT_PIDS=()    ;; esac
case $(declare -p _QENV_EDIT_TARGETS 2>/dev/null) in 'declare -a'*'=('*) ;; *) unset -v _QENV_EDIT_TARGETS; declare -ga _QENV_EDIT_TARGETS=() ;; esac
case $(declare -p _QENV_EDIT_BEFORES 2>/dev/null) in 'declare -a'*'=('*) ;; *) unset -v _QENV_EDIT_BEFORES; declare -ga _QENV_EDIT_BEFORES=() ;; esac
