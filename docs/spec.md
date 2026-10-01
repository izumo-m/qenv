# qenv — design specification

**qenv = quarantined env.** A direnv-like environment variable manager that quarantines your
environment variables outside your repositories, under `~/.config/qenv`. It prevents secrets from
leaking into git by construction rather than by convention.

**Requirement (the contract): bash 5.x.** Development and verification are done on bash 5.x.
qenv relies on `declare -g`, associative arrays, and the format of `declare -px` output — one line
per variable and reusable as input (newlines and the like in values are folded into `$'…'`) — so
shells without these (older bash, zsh, …) are out of scope.

---

## 1. What it solves

direnv puts `.envrc` in the working directory. When that
directory is inside a repository, this has weaknesses.

- The `.envrc` is easy to leak by accident with `git add`.
- Because the file lives somewhere untrusted, every change requires a `direnv allow` approval.
- It cannot be used where you cannot put the file (directories you cannot write to, such as `/etc`).

qenv puts `qenv.enter` outside the repository, in a "mirror tree" under `~/.config/qenv`. That
removes the weaknesses.

- There is no secret file in the repository. Nothing can leak into git.
- You only ever source what you put there yourself. No `direnv allow` equivalent is needed.
- Because `qenv.enter` lives outside the target directory, it can also apply to `/etc`, `/opt`, or
  paths owned by someone else.

---

## 2. How it works, in outline

The design comes down to four points.

**(1) Separate the directory from `qenv.enter`.**
qenv places nothing in the working directory. `qenv.enter` is quarantined under `~/.config/qenv`,
mirroring `$PWD` (§3).

**(2) Load on entry, roll back on leaving.**
Entering a directory sources its `qenv.enter` (§6). Leaving always rolls back.
If you need cleanup such as stopping a process, write
a `qenv-leave` function inside `qenv.enter` (§7).

**(3) Only exported variables are rolled back.**
The exported variables `qenv.enter` touched are restored from a diff (§8). Bare (non-exported)
variables, functions, and arrays are out of scope. This is the same trade-off direnv makes.

**(4) All functionality lives in a single `qenv` function.**
Sourcing `qenv.sh` from `.bashrc` defines the public function `qenv`, the internal `_qenv_*`
functions, and the `_QENV_*` state variables (naming conventions in §10).

The user registers the **trigger**. With `PROMPT_COMMAND=qenv`, `qenv` runs at every prompt,
and leaves and enters only at the moment `cd` changes which `qenv.enter` should apply (§5).
Which `qenv.enter` applies is determined by cwd alone; it does not depend on the route you
took to get there.

---

## 3. Where files live

qenv creates a directory that mirrors `$PWD` and places a single `qenv.enter` inside it. Paths are
normalized with realpath.

| Working directory | Location of qenv.enter |
|---|---|
| `/home/you/work` | `~/.config/qenv/home/you/work/qenv.enter` |
| `/home/you/work/sub` | `~/.config/qenv/home/you/work/sub/qenv.enter` |
| `/etc` | `~/.config/qenv/etc/qenv.enter` |
| `/` (the global default) | `~/.config/qenv/qenv.enter` |

- The only fixed name is **`qenv.enter`**. It is sourced when you enter the directory.
- Leave-time handling goes in the **`qenv-leave` function** defined inside `qenv.enter` (§7). There
  is no separate file.
- The root is `QENV_ROOT` (default `${XDG_CONFIG_HOME:-$HOME/.config}/qenv`).
- These files always live under `QENV_ROOT`, which means they are yours.
  Since nothing is written into the target directory, you can attach a `qenv.enter` to places you
  cannot write to.

### Why a mirror tree rather than flattened names

Emacs backups and Claude's `~/.claude/projects/` use "flat encoding", collapsing a path hierarchy
into a single name (`/`→`-`, for instance). qenv does
not; it uses a mirror tree. There are three reasons.

- **Walking up to ancestors becomes natural.** `$PWD` maps directly onto a location under
  `QENV_ROOT`, and you walk up to ancestors by trimming the tail (§4).
  Unlike Emacs and Claude, qenv uses the **hierarchy (the parent-child relationship) of the path
  itself**, so it cannot throw that structure away.
- **A human can navigate it with cd, ls, and completion.** Flat names are unreadable.
- **No encoding is needed.** A conversion such as `/`→`-` makes `/home/foo-bar` and `/home/foo/bar`
  collide.
  A mirror uses the path as-is, so there is no ambiguity.

The name collision between files and directories — the very thing flat encoding
tries to avoid — does not happen in a mirror tree either. `work/qenv.enter` (a
file) and `work/sub/` (a directory) coexist without trouble (verified).

---

## 4. Finding qenv.enter

qenv walks up one level at a time from cwd and uses the first `qenv.enter` it finds. The search
stops
as soon as one is found.

```bash
_qenv_find() {                # $1 = realpath-normalized directory. The result goes to _QENV_FOUND_ENTER
  local dir="$1" f
  while :; do
    f="$QENV_ROOT${dir%/}/qenv.enter"  # ${dir%/} avoids // when dir is /
    [[ -e $f ]] && { _QENV_FOUND_ENTER="$f"; return 0; }
    [[ $dir == / ]] && { _QENV_FOUND_ENTER=""; return 1; }  # stop after walking up to /
    dir=${dir%/*}; [[ -z $dir ]] && dir=/
  done
}
```

The key points are these.

- **Walk all the way up to `/`** (do not stop at `$HOME`). A `qenv.enter` is yours, so it can be
  attached under system directories such as `/etc`.
  Since the search stops as soon as one is found, the cost does not grow as long as you do not use
  anything outside `$HOME`.
- **On reaching `/`, look at `$QENV_ROOT/qenv.enter`.** That is the default shared by every
  directory.
  If you do not create it, nothing happens (opt-in).
- **The result is assigned to the global `_QENV_FOUND_ENTER`.** No command substitution is used, so
  no subprocess is forked.
- **The test is existence, `[[ -e ]]`, and nothing more.** Whether it is readable is source's job.

The last point matters. Testing with `-r` (readable) would skip a `qenv.enter` that exists but
cannot
be read and silently apply the parent's instead — an accident that loads the wrong secrets. With
`-e` (exists), qenv stops at the nearest one, and if it cannot be read, source fails loudly with
`Permission denied` (verified).

Even if `qenv.enter` is a directory, source fails harmlessly (`is a directory`). The only thing that
hangs is a FIFO or another special file, and that only happens if you ran `mkfifo` yourself.
`qenv edit` creates regular files only, so it cannot happen by accident.

---

## 5. Triggering and syncing

Sourcing `qenv.sh` does four things.

- Refuses to load on bash older than 4 (associative arrays and `declare -g` are required)
- Defines the functions (`qenv` and `_qenv_*`)
- Prepares `QENV_ROOT` (sets the default; creates it with mode 700 if absent)
- Initializes the state variables (§10)

It does **not** touch `PROMPT_COMMAND`. Registering the trigger is up to the user.

```bash
PROMPT_COMMAND=qenv     # qenv.sh does not touch PROMPT_COMMAND
```

With this, `qenv` (with no arguments) runs at every prompt and enters or leaves only
when PWD has changed. Calling it by hand with `cd somewhere; qenv` does the same thing.

The role of `qenv` depends on its arguments: with none it is the sync body, with arguments it is a
helper command (§9).

```bash
qenv() {
  local __ret=$?                              # save the previous command's $? (see "Handling $?" below)
  [[ -n ${_QENV_BUSY:-} ]] && return $__ret   # re-entry guard (below)
  local _QENV_BUSY=1
  [[ -n ${_QENV_ENTERING:-} ]] && unset -v _QENV_ENTERING  # clean up after a ^C interrupt (see the exec loop guard below)
  (( $# )) || {                                # no args = the sync body. $? is passed through
    [[ -n ${_QENV_DISABLED:-} ]] && return $__ret   # do not sync while disabled (§9)
    _qenv_edit_pending; _qenv_sync; return $__ret
  }
  case $1 in
    status)          _qenv_status ;;
    edit)            _qenv_edit "${2:-.}" ;;
    enable)          _qenv_enable ;;          # resume syncing and re-check where we are (§9)
    disable)         _qenv_disable ;;         # stop syncing (state is left as is, §9)
    reload)          _qenv_reload_now ;;      # force a leave→enter where we are (§9)
    help|-h|--help)  _qenv_help ;;
    *) printf 'qenv: unknown command: %s\n' "$1" >&2; _qenv_help >&2; return 2 ;;
  esac
}

_qenv_sync() {                                # sync to the qenv.enter that applies to cwd
  [[ "$PWD" == "$_QENV_PREV_PWD" ]] && return     # PWD unchanged: return at once (most prompts end here)
  _QENV_PREV_PWD="$PWD"
  local dir; dir=$(pwd -P)                    # realpath normalization, only when PWD changed
  _qenv_find "$dir"                           # → _QENV_FOUND_ENTER
  [[ "$_QENV_FOUND_ENTER" == "$_QENV_ACTIVE_ENTER" ]] && return  # the same qenv.enter applies: nothing to do
  [[ -n "$_QENV_ACTIVE_ENTER" ]] && _qenv_leave            # leave the old qenv.enter
  if [[ -z "$_QENV_FOUND_ENTER" ]]; then
    _QENV_ACTIVE_ENTER=""
  elif [[ "$_QENV_FOUND_ENTER" == "$_QENV_SKIP_ENTER" ]]; then
    _QENV_ACTIVE_ENTER=""                                  # exec loop guard (below). Not recorded as entered either
    _qenv_pretty "$_QENV_FOUND_ENTER"                      # shorten a leading $HOME/ to ~/ for display (§10)
    _qenv_notify "enter suppressed (exec loop guard): $_QENV_PRETTY"
  else
    _qenv_enter "$_QENV_FOUND_ENTER"; _QENV_ACTIVE_ENTER="$_QENV_FOUND_ENTER"
  fi
}
```

The flow of a sync is simple.

1. If PWD is the same as last time, return immediately. The per-prompt cost is this one line.
2. If it changed, normalize with realpath and find the applicable `qenv.enter` with `_qenv_find`.
3. If the applicable `qenv.enter` is the same as before, do nothing.
4. If it differs, leave the old `qenv.enter` and enter the new one.

Leave comes first, enter second. That is why, even when switching between `qenv.enter` files, the
old
one's `qenv-leave` correctly runs first.

Because qenv normalizes with realpath, different symlink paths that point at the same real
location share the same `qenv.enter`. The behavior is consistent regardless of the route.

### Handling `$?` (the previous command's exit status)

`qenv` saves `$?` on entry and returns it unchanged from the sync body. Here is why, step by step.

**bash saves and restores `$?` around PROMPT_COMMAND automatically (verified).**
So the next command you type, or `echo $?`, always sees the correct value no matter what qenv does.
For that purpose the save is unnecessary.

**There is exactly one case where the save matters:** when a tool that reads `$?` follows qenv
inside
the same PROMPT_COMMAND. bash does *not* reset `$?` between commands *inside* PROMPT_COMMAND.
So with `PROMPT_COMMAND='qenv; exit-status-prompt'`, without the save that prompt would pick up
qenv's internal `$?` (always the same value) and the exit-status display would be broken (verified).
Since qenv is recommended to go first, this ordering is likely to occur.

The save is written as the **single statement** `local __ret=$?`.
Splitting it into `local __ret; __ret=$?` turns `$?` into 0, because
`local` itself succeeds, so the saved value is useless (verified).

`_qenv_sync`'s exit status is not returned. Returning it would defeat the save and reintroduce the
bug above. The success or failure of the hook carries no meaning, and problems such as a failed
source are reported on stderr, so there is no need to convey them through a return value.

Subcommands (`qenv status` and friends) are run by hand, so they are not transparent: each returns
its own exit status.

### The re-entry guard (`_QENV_BUSY`)

Both the source that enter performs and the `qenv-leave` that leave
calls are arbitrary code, so **they can call qenv back**. For example,
something inside `qenv.enter` (a prompt-updating function, say) calls
`eval "$PROMPT_COMMAND"`, which calls `qenv` again.

Left alone, this re-entry does real damage. There
are two examples that have happened or could happen.

- **Re-entry while resolving a pending edit.** If qenv is re-entered while it is reloading to
  resolve a pending edit (a ^Z-suspended edit being followed up, §9), the unresolved entry
  becomes visible a second time, producing infinite recursion: reload → enter → re-entry → …
  (this actually happened).
- **A nested enter from a `qenv.enter` containing `cd`.** A `cd` inside `qenv.enter` is a sanctioned
  use (§6).
  A `_qenv_sync` re-entered after the cd performs a **nested** enter. The inner `_qenv_diff_build`
  then consumes and discards the temporary `_QENV_DIFF_BASE` belonging to the enter in progress.
  Having lost its baseline, the outer `_qenv_diff_build` compares against an empty baseline and
  builds a restore function that **unsets every currently exported variable**.
  The next leave then wipes out `PATH` along with everything else.

Defending this with per-site ordering rules alone is fragile, so **re-entry is cut off in one place,
at the dispatcher's entry point**. If `_QENV_BUSY` is set, return without doing anything — that is
all. For a re-entry, "nothing happens" is the correct behavior (in the examples above, the point of
the call-back is the caller's own work — updating the prompt — not qenv's).

The flag is set with **`local`**. bash local variables are dynamically
scoped, so the flag is visible only to what qenv calls (all the way
into the `qenv.enter` being sourced) and disappears automatically
when qenv returns. **Even when interrupted by ^C**, the function scope unwinds and clears it, so
there is no risk of the classic global-flag accident where it stays set and qenv stops working
entirely from then on.

The per-site ordering rules — `_QENV_PREV_PWD` is updated before the enter (`_qenv_sync`), the
pending list is emptied before the reload
(`_qenv_edit_pending`) — are kept as a second line of defense.

### The exec loop guard (`_QENV_ENTERING` / `_QENV_SKIP_ENTER`)

There is one more infinite loop the re-entry guard cannot protect against: **the shell being
replaced by a new interactive shell in the middle of an enter's source**.

For example, `qenv.enter` (or an external command it calls) misjudges that it was "executed" when it
was in fact sourced, and runs `exec -a "$0" $SHELL`. Using `[ "$BASH_SOURCE" != "$0" ]` to tell
sourcing from execution produces exactly this misjudgment.

That misjudgment happens **in a shell started by that same command with `exec -a "$0"`**, because
`exec -a "$0"` leaves that shell's `$0` set to the command's own path.

1. Running the command starts an interactive shell whose `$0` is still the command's path.
2. The new shell runs qenv from bashrc and enters `qenv.enter`.
3. `qenv.enter` sources that command. Because `$0` and
   `BASH_SOURCE` match, it misjudges that it was "executed".
4. The command runs `exec $SHELL` and replaces the shell that was in the middle of an enter. `$0` is
   still the command's path — back to step 2, an infinite chain.

This loop is **impossible to prevent with `_QENV_BUSY`**, because the guard applies only to function
calls within one shell, while exec rebuilds the entire process image. Worse, **exec does not change
the PID**, so it cannot be detected by comparing PIDs either. The only thing that survives across
the
process boundary is the environment, so qenv detects it with an environment marker.

- **`_qenv_enter` exports `_QENV_ENTERING=<path to qenv.enter>` only while sourcing**, and unsets it
  on completion (it is set after the baseline is captured and cleared before the comparison, so it
  never shows up in the diff).
- In normal operation this variable never survives into a process's environment. **If it is still
  present when qenv.sh loads**, it is certain that this shell was exec'd or started in the middle of
  an enter. Auto-entering that same file would loop, so its path is moved to `_QENV_SKIP_ENTER` and
  a warning is printed.
- `_qenv_sync` **does not enter** a file matching `_QENV_SKIP_ENTER`. It is not made active either,
  so `cd`-ing away produces no spurious leave, and coming
  back simply prints the suppression notice again.
- **The suppression lifts itself when an enter completes** (end of `_qenv_enter`). The reload
  performed by `qenv edit` deliberately **bypasses** the suppression: a re-read right after the user
  fixed the file is exactly what should be allowed through.
  If it is not fixed yet, the exec happens one more time and the new shell suppresses it again and
  stops. It does not go back into the loop.
- If an enter is interrupted by ^C, `_QENV_ENTERING` can be left set. It is cleaned up as a leftover
  at the dispatcher's entry point (right after passing the re-entry guard, i.e. once we know this is
  top level). A qenv call made while an enter is running returns at the `_QENV_BUSY` check before
  that, so a marker for an enter in progress is never cleared by mistake.

Incidentally, commands like these would not misfire if they detected sourcing by whether a
`return` in a subshell succeeds (`(return 0 2>/dev/null)` succeeds while being sourced and errors
while being executed; it does not depend on `$0`). The guard on qenv's side covers every arrangement
in which "something `qenv.enter` calls starts or replaces a shell".

### Coexisting with other PROMPT_COMMAND tools

qenv.sh never manipulates `PROMPT_COMMAND`. How and in what order to register it is up to the user.
There are two pieces of advice.

- Avoid string concatenation, `PROMPT_COMMAND="$PROMPT_COMMAND; qenv"`; use an assignment.
  Concatenating onto the array form in bash 5.1+ drops the
  elements other than `[0]` (`__git_ps1`, for instance).
- Put qenv **first, or at least early**. If it goes last, the rendering tools run first and build
  PS1 while the old environment variables are still in place.
  The result is that the settings from `qenv.enter` appear on screen one prompt late.

---

## 6. enter: loading the environment variables

enter captures a baseline for the rollback, sources
`qenv.enter`, and builds a restore function from the diff.

```bash
_qenv_enter() {                # $1 = path to qenv.enter
  local enter=$1
  unset -f qenv-leave          # drop the qenv-leave defined by the previous qenv.enter
  _qenv_diff_capture           # capture the exports before source as the baseline (§8)
  export _QENV_ENTERING=$enter # exec-detection marker, set only while sourcing (§5, the exec loop guard)
  set --                       # empty the positional parameters (see below)
  _qenv_pretty "$enter"        # shorten a leading $HOME/ to ~/ for display (§10)
  _qenv_notify "enter $_QENV_PRETTY"  # printed before source (the file is known even if it never returns; symmetric with leave)
  source "$enter"              # a plain source (no set -a)
  unset -v _QENV_ENTERING      # completed → clear the marker
  _qenv_diff_build             # build _qenv_restore from the baseline-vs-current diff (§8)
  hash -r                      # clear the command hash (§8)
  if [[ $_QENV_SKIP_ENTER == "$enter" ]]; then  # it completed = no longer dangerous → lift the suppression
    _QENV_SKIP_ENTER=
  fi
}
```

### Why `set --` before source

An argument-less `source` inherits the caller's positional parameters, so without this,
`_qenv_enter`'s `$1` (the path to `qenv.enter`) would leak into the `$@` of `qenv.enter` and of any
helper it sources. A helper built around "run it if there are arguments" (`[ $# -gt 0 ] && "$@"`)
would then try to execute the path of `qenv.enter` itself, which fails with `Permission denied`
because the file is 0600.

Inside a function, `set --` empties only that function's `$@` (it does not affect the caller), so
`$@` inside `qenv.enter` is always empty. The path was saved into `local enter` beforehand.

### Why a plain source

qenv does not use `set -a`. Because the source is plain, bash's own distinction holds as it should:
`export NAME=value` is an environment variable, a bare `NAME=value` is a non-exported shell
variable.
A bare variable is useful for "an intermediate value I do not want to pass to children".

```bash
base=/opt/app                  # bare (not leaked to children, not rolled back)
export PATH="$base/bin:$PATH"
```

Bare variables are not rolled back; they survive after you leave. If you use one for secret work,
`unset` it yourself at the end of `qenv.enter`.

### Writing a `qenv.enter`

- **The basics:** variable assignments, `export`, and the definition of a `qenv-leave` function.
  A `qenv-leave` definition survives globally even though
  the source happens inside a function (verified).
- **Mind the scope (`declare` / `typeset` / `local` / `readonly` / arrays):** everything follows
  bash's scope rules exactly, and what you write is usable within that scope.
  Because the source happens inside a function, `declare` / `typeset` / `local` (without `-g`)
  become local variables that last only for the duration of that source and vanish when the enter
  finishes. To make them stick in the shell, use `NAME=value`, `export`, or `declare -g`.
  `readonly` can be neither changed nor unset, so it cannot be rolled back (marking an exported
  variable readonly makes the restore at leave fail). Arrays remain in the shell, but they are not
  exported and therefore not rolled back.
- **Understand that it is not isolated:** `cd` (pushd/popd), `set`, `shopt`, and `trap` remain in
  the current shell, because the source is plain.
  This is not a defect but a property. You can use it deliberately.
  - Example: installing `trap qenv-leave EXIT` makes `qenv-leave` run when the shell exits too
    (where the automatic leave does not run, §12).
    If `qenv-leave` does its cleanup and then releases the trap with `trap - EXIT`, one function
    covers both leaving by cd and exiting.
  - Caution: whatever you `cd` to stays, so go back yourself if you do not want that.
    `exit` alone terminates the whole shell, so writing
    it means "the shell closes the moment you enter".

Ordinary leave-time handling goes in the `qenv-leave` function (§7). To cover shell exit as well,
add
the `trap qenv-leave EXIT` shown above.

---

## 7. leave: cleanup hook and rollback

leave has two stages: first the cleanup hook, then the rollback.

```bash
_qenv_leave() {
  _qenv_pretty "$_QENV_ACTIVE_ENTER"              # shorten a leading $HOME/ to ~/ for display (§10)
  _qenv_notify "leave $_QENV_PRETTY"              # printed before the hook and the rollback (§10)
  declare -F qenv-leave >/dev/null && qenv-leave  # (1) the cleanup hook, if any, while qenv.enter is still in effect
  _qenv_restore 2>/dev/null                       # (2) always roll back
  unset -f qenv-leave _qenv_restore 2>/dev/null   # tidy up
  hash -r
}
```

| `qenv-leave` function | Behavior on leave |
|---|---|
| not defined | rollback only |
| defined | `qenv-leave` is called first, then the rollback always runs |

- **The rollback always runs.** The exported variables set by `qenv.enter` are always restored once
  you leave the subtree.
  As with direnv, "leaving returns you completely". There is no need to call anything by hand, and
  there is no `qenv restore` command.
- **`qenv-leave` runs before the rollback.** That is the crux. It can still read the variables
  `qenv.enter` exported, so it can run `ssh-agent -k` (which reads `$SSH_AGENT_PID`) or shut down a
  server.
  After the rollback the variables are gone, and `qenv-leave` could no longer stop anything.

Examples:

```bash
eval "$(ssh-agent -s)"                     # exports SSH_AGENT_PID and friends
qenv-leave() { ssh-agent -k; }             # stop the agent on the way out (runs before the rollback)
```

```bash
export DB_URL=postgres://localhost/dev
_dev_pid=$(start-dev-server)               # keep it in a bare variable
qenv-leave() { kill "$_dev_pid"; }         # stop it on the way out (the rollback is automatic)
```

`qenv-leave` is a hook written by the user, which is why it has a hyphenated name. It is
distinct from the internal function `_qenv_leave` that orchestrates the whole leave (§10).

Note that leave does not run when the shell exits. See §12 for the caveats.

---

## 8. How the rollback works

### Capture a baseline, build a restore function from the diff

The rollback uses no temporary files. Instead, qenv assembles a shell function on the spot. Two
functions form a pair.

- **`_qenv_diff_capture` (capture the baseline):** before the source, record the currently exported
  variables in `_QENV_DIFF_BASE`.
  Its contents are an associative array of "variable name → `declare -p` output".
- **`_qenv_diff_build` (build the restore):** after the source, compare the baseline against the
  current state, produce the diff, and define the `_qenv_restore` function with `eval`. Finally,
  clean up the baseline (`_QENV_DIFF_BASE`) with `unset`.

Both scans work on the **single bulk output of `declare -px`**. `declare -px` prints one line per
variable (newlines and the like in values are folded into `$'…'`) in the same format as a per-name
`declare -p`, so lines can be recorded verbatim and compared as strings. The
straightforward version takes `$(declare -p name)` per variable. That forks a
command substitution for each one and makes enter visibly slow in environments with
many exported variables, so qenv does not use it (in bulk there is a single fork).

`_QENV_DIFF_BASE` is global but is **not exported**. Exporting it would leak the old exported values
(which may contain secrets) to child processes, and would eat into `ARG_MAX`.

There are three kinds of diff to restore.

| What `qenv.enter` did | Restore |
|---|---|
| newly exported it | `unset` it |
| changed the value | put the old value back |
| unset / de-exported it | put the old value back |

Every restore is unified on `declare -gx` (global plus export). It is just a matter of adding `-g`
to
the `declare -p` output and running `eval`.

**Edge case:** if `qenv.enter` exports a variable that **was originally non-exported**, leaving
unsets
it rather than returning it to its old (non-exported) state, because only exported variables are
recorded in the baseline. This is rare and accepted.

### Variables excluded from the rollback

The exclusions are the **variables the shell manages itself**. Rolling these back would, in the case
of `PWD` for example, also undo a `cd` performed inside `qenv.enter`.

Since the diff only looks at exported variables (`declare -px`), non-exported shell-managed
variables
(`RANDOM`, `SECONDS`, `BASH_*`, `COMP_*`, …) never enter it in the first place. Only the three that
are **both exported and shell-managed** are excluded explicitly.

```bash
_qenv_excluded() { case $1 in PWD|OLDPWD|SHLVL|_) return 0 ;; *) return 1 ;; esac; }
```

`PATH`, `HOME`, `LANG`, and the like are not excluded. The shell does not change them on its own, so
if `qenv.enter` changed one, that is a genuine change. The `_` in the `case` is a safety net (it
does
not appear in `declare -px`).

### QENV_KEEP (user-defined rollback exclusions)

Besides the shell-managed variables, the user can use `QENV_KEEP` to name variables they do not
want rolled back. It is a whitespace-separated list of variable names, and globs may be written
(e.g. `QENV_KEEP='KUBECONFIG AWS_*'`).

```bash
_qenv_kept() {                # 0 if $1 matches QENV_KEEP (whitespace-separated, globs allowed)
  [[ -n ${QENV_KEEP:-} ]] || return 1
  local -a pats; local pat
  read -ra pats <<< "$QENV_KEEP"                     # read -ra: split without pathname expansion
  for pat in "${pats[@]}"; do
    [[ $1 == $pat ]] && return 0
  done
  return 1
}
```

The test applies **only to `_qenv_diff_build` (building the restore)**, not to `_qenv_diff_capture`
(capturing the baseline).

- Excluding as far back as the capture would mean that if `qenv.enter` **narrows** `QENV_KEEP`, a
  pre-existing variable is misread as "absent from the baseline = newly exported" and gets unset
  when you leave.
- Extra entries in the baseline do no harm. If no restore is built for them, they are simply thrown
  away along with `_QENV_DIFF_BASE`.

The test is applied in **both** of build's loops (the scan of "currently exported" and the scan of
"in
the baseline but gone now"). Forgetting the latter would resurrect a KEEP-listed variable when you
leave
after `qenv.enter` had unset it.

Evaluation happens on every enter (when the restore is generated), so you are free to set it
whenever
you like. It works both as a global setting in `.bashrc` and as `export QENV_KEEP=NAME` inside a
`qenv.enter` (for that environment only; `QENV_KEEP` itself is a newly exported variable and
disappears when you leave).

qenv splits the patterns with `read -ra`. A plain `for pat in $QENV_KEEP` would let a glob undergo
pathname expansion into filenames in cwd and be corrupted (the right-hand side of `[[ $1 == $pat ]]`
is not pathname-expanded).

### hash -r (clearing the command location cache)

When `qenv.enter` rewrites PATH, bash's command hash keeps pointing at the old binaries (the same
applies when leave puts PATH back). `hash -r` is run on both enter and leave to clear it.

qenv does not test whether PATH was touched; `hash -r`
runs **unconditionally**. Skipping the test keeps things
simpler, and it does no harm for a `qenv.enter` that never touches PATH.

### Notes

- The restore information lives in a shell function (in memory). It is not exported, so `ARG_MAX` is
  irrelevant. Its contents are a handful of old values, a few KB at most.
- There is no stack, even when nested. Exactly one `qenv.enter` is ever in effect, so there is
  exactly one set of restore information.
  Switching between `qenv.enter` files means "restore first, then enter the new one".
- The capture happens only on enter and leave, not at every prompt.

---

## 9. Command reference

qenv consolidates the helpers into subcommands. There are no separate commands such as `qenv-edit`.

| Invocation | Behavior |
|---|---|
| `qenv` | (no arguments) evaluate the current directory and enter/leave. The main body, called from PROMPT_COMMAND |
| `qenv status` | Show the current state: the path of the active `qenv.enter`, whether `qenv-leave` is defined, edits pending because of ^Z, any suppressed file, and whether it is disabled (`state: disabled`) |
| `qenv edit [DIR]` | Open DIR's `qenv.enter` (default `.`) in `$EDITOR`. Confirmation only when creating a new file |
| `qenv enable` | Unfreeze, re-check where we are, and leave/enter if it differs from active |
| `qenv disable` | Freeze (safe mode). Stops syncing as well as enter/leave/reload. The current state is unchanged |
| `qenv reload` | Force the `qenv.enter` that applies here to be re-read with leave→enter (a no-op while disabled) |
| `qenv help` / `-h` / `--help` | Usage |

- `qenv edit [DIR]` normalizes DIR with realpath and opens the corresponding `qenv.enter` under
  `$QENV_ROOT` in `$EDITOR`.
- **A non-existent DIR is an error** (`qenv: no such directory`). That is the guard against typos.
  What gets created is `qenv.enter`, never DIR.
- **Confirmation with `create <path>? [y/N]` (defaulting to No) happens only when `qenv.enter` does
  not exist yet.** On No, nothing is created and it exits.
  Editing an existing file opens immediately without confirmation.
- The mirror-side directory is created with `mkdir -p` under `umask 077` whenever the editor is
  launched (the target directory itself is not created).
  Since `qenv.enter` contains secrets, new files are created with mode 0600 (directories 0700).
- `$EDITOR` is expanded unquoted, so editors with arguments such as `EDITOR="code --wait"` work
  (`vi` if unset).
- **Saving applies the change on the spot.** qenv compares the mtime before and
  after the edit, and acts only when the file was saved (created or overwritten).
  Further, it leaves and re-enters the current environment only when the edited `qenv.enter` is the
  nearest one for where we are.
  That way, editing the active `qenv.enter` takes effect immediately.
  An edit that was not saved, or an edit of a `qenv.enter` that does not apply here (an unrelated
  directory, or an ancestor that is shadowed), does not change the environment.
  mtimes are compared at **nanosecond precision** (`stat -c %.Y`). At second precision (`%Y`),
  opening an existing file and saving within the same second would be misread as unchanged and the
  change would be missed.
- **Suspending with ^Z still applies the change after the editor exits.** ^Z stops only the editor's
  subshell; the body of `_qenv_edit` carries straight on (bash returns control with 128+signal
  number = 147–150 (STOP/TSTP/TTIN/TTOU) when it detects a stopped child).
  Looking at the mtime at that point is too early (nothing is saved
  yet), so qenv gives up on applying it immediately and defers instead.
  The PID of the job `%+` that just stopped, the target path, and the mtime before the edit are
  pushed onto the watch lists `_QENV_EDIT_PIDS` / `_QENV_EDIT_TARGETS` / `_QENV_EDIT_BEFORES`
  (parallel arrays).
  These pending entries are followed up by `_qenv_edit_pending` at the top of `qenv` at every
  prompt.
  While the editor is alive (including stopped) it waits; once it detects the exit, it removes the
  entry from the list, compares the mtime, and calls `_qenv_reload` if the file was saved. In other
  words, the change takes effect at the first prompt after `fg` → save → quit.
  It works under the same conditions as immediate
  application (saved, and the nearest one for where we are).
- **Several edits can be pending at once.** The lists are arrays so that you can suspend one edit
  with ^Z and then edit a different `qenv.enter` and suspend that too.
  With a single slot, the second pending entry would silently clobber the first and the first edit's
  save would never be applied. When the same target is edited again, both entries are kept and
  thinned at resolution time to "reload each target only once" (reload re-reads the file's current
  contents, so the result is consistent no matter which pending entry resolves it).
- **Confirm that what just stopped really is this editor before pushing.** An editor that merely
  exited with status 147–150 produces the same rc as a stop. Grabbing `%+` unconditionally at that
  point would start watching an unrelated stopped job by mistake.
  So a no-op marker `: qenv-edit` is placed at the head of the subshell, and the entry is deferred
  only when that marker is visible in the job text (`jobs %+`).
  The marker alone cannot reject the case where `%+` is "another qenv-edit suspended earlier" (the
  text is identical), so when `%+`'s PID is already on the watch list, qenv concludes that nothing
  stopped just now and falls through to the normal path (mtime comparison → immediate application).
  If this were left unhandled, applying a saved edit
  would be delayed until the older editor exits, and two
  pending entries with the same PID would pile up.
- **Exit is detected with both `kill -0` and the job table (`_qenv_is_job`).** With `kill -0` alone,
  if the PID were reused by another process after the editor died, qenv would keep waiting on an
  unrelated process forever.
  It waits only while "the PID is alive and still in `jobs -p`"; once it is gone from the job table
  (including when it was `disown`ed), the entry is followed up and closed out at that point.
- **Entries come off the list before the reload (a doubled re-entry guard).** Re-entry is normally
  cut off at the dispatcher by `_QENV_BUSY` (§5), but in addition, the list is emptied before the
  reload so that an entry being resolved can never become visible again.
  It is also why a ^C in the middle of a reload does not
  cause a storm of retries at the next prompt (crash-safe).
- The only file that is edited is the single `qenv.enter` (leave is a function in the same file), so
  there is exactly one edit command, `edit`.
- The rollback is always automatic on leave, so there is no `restore` command. There is no `path`,
  `list`, or `exec` either.

### enable / disable / reload (manual control)

A change of cwd triggers automatic syncing. For the workflows "I want to pause this for a
while" and "I want to re-read without moving", there are three manual commands. All of them run
inside the dispatcher's `_QENV_BUSY` (§5), so re-entry
is cut off even if an enter calls `PROMPT_COMMAND` back.

**`qenv disable` (freeze = safe mode)**

Sets the internal flag `_QENV_DISABLED` (§10). **Nothing about the
current state — the active `qenv.enter` and the environment variables
— changes.** From then on, qenv reads no `qenv.enter` (no enter)
and performs no rollback (no leave). All three paths that
touch the environment are stopped at their entry points.

- An argument-less `qenv` returns early, before `_qenv_sync`.
- `qenv reload` (`_qenv_reload_now`) checks the flag at its entry and becomes a no-op.
- Applying a save from `qenv edit` (`_qenv_reload`) likewise becomes a no-op.

You can still open, edit, and save files with `qenv edit`, but the contents are not applied. The
flag
is not `export`ed; it is state confined to that shell.

**Why stop enter/leave/reload as well.** The main purpose is to break the chain in which re-reading
a
broken `qenv.enter` makes things worse. While frozen, the file is not read, so you can safely fix a
`qenv.enter` containing a mistake. Letting `reload` through while disabled would load the
still-broken
file and could damage the environment again — so `reload` is stopped too.

**`qenv enable` (unfreeze)**

Clears the flag and then re-checks where we are. The implementation just empties `_QENV_PREV_PWD`
and
calls `_qenv_sync`. `_qenv_sync` returns early at its first line when PWD is unchanged (§5), so
emptying it forces a fresh start from the find.

- If the **path** of the `qenv.enter` that should apply
  differs from the active one, it leaves and enters;
  if it is the same, nothing happens. Even if you moved elsewhere while disabled, enable lines
  things up correctly with wherever you run it.
- `enable` is a **path comparison**. When you have fixed only the **contents** of the same file, the
  path has not changed and it is not re-sourced. To apply it, follow up with `qenv reload`.

**`qenv reload` (forced re-read)**

Finds the `qenv.enter` that applies where we are with `_qenv_find` and, if something is active,
always
leaves it before entering again (`_QENV_ACTIVE_ENTER` and `_QENV_PREV_PWD` are updated too). Use it
when you rewrote the file by hand rather than through `qenv edit`, or when you want to apply a
content
change after `enable`.

- **It is a no-op while disabled** (to prevent the chain described above). Run `qenv enable` first.
- After enable, it attempts the enter even for a file suppressed by the exec loop guard
  (`_QENV_SKIP_ENTER`); if the enter completes, the suppression lifts itself (§5).
- It is distinct from the `_qenv_reload` internal to `qenv edit` (which applies only when
  the edited file is the nearest one for where we are).
  `reload` re-reads the file that applies here unconditionally.

These are not "a replacement for automatic syncing" but "a temporary override". New shells always
start enabled, and `disable` is confined to that shell. The typical recovery procedure is
**`qenv disable` → `qenv edit` (fix it) → `qenv enable` → `qenv reload`**.

---

## 10. Naming conventions and state variables

### Naming conventions

The prefix denotes the kind.

| Prefix | Kind | Example |
|---|---|---|
| `qenv` | public command | `qenv`, `qenv status` |
| `qenv-*` (hyphen) | user-defined hook | `qenv-leave` |
| `_qenv_*` | internal function | `_qenv_sync`, `_qenv_find` |
| `QENV_*` | public configuration variable | `QENV_ROOT`, `QENV_QUIET`, `QENV_KEEP` |
| `_QENV_*` | internal state variable | see the table below |

Names are meant to convey what a thing is and does. Related things share a stem.
For instance, `_QENV_FOUND_ENTER` and `_QENV_ACTIVE_ENTER` are both paths to a `qenv.enter`, and
`_qenv_diff_capture`, `_qenv_diff_build`, and
`_QENV_DIFF_BASE` are one set belonging to the diff machinery.

### Public configuration (`QENV_*`)

| Variable | Purpose |
|---|---|
| `QENV_ROOT` | The root of the mirror tree (default `${XDG_CONFIG_HOME:-$HOME/.config}/qenv`) |
| `QENV_QUIET` | Non-empty: suppress the enter/leave notifications |
| `QENV_KEEP` | Exported variables not to roll back (whitespace-separated, globs allowed). Applies only when the restore used at leave is generated |

enter and leave each print one line to stderr: `qenv: enter <path to qenv.enter>` on entry and
`qenv: leave <that path>` when leaving.
The verb labels (enter / leave) are aligned so the direction is obvious at a glance.
Nothing is printed when PWD has not changed. `QENV_QUIET`
(non-empty) exists solely to stop these notifications.

When a path is displayed, a leading `$HOME/` is shortened to `~/` (`_qenv_pretty`; the same applies
to
status, edit, help, and the exec loop guard messages as well as the notifications).
This is **display-only formatting**: the internal state (`_QENV_ACTIVE_ENTER` and so on) and the
paths
used for finding, sourcing, and mtimes remain absolute.
To avoid forking a command substitution, the result is returned through the variable `_QENV_PRETTY`
rather than through output.

Both lines are printed **before** the work. enter prints before the `source`, leave before
`qenv-leave` and the rollback. That way, even if `source` or `qenv-leave` never returns because it
hangs, `exec`s, or `exit`s, the line just before it shows which `qenv.enter` was being processed.

### Internal state (`_QENV_*`)

| Variable | Purpose |
|---|---|
| `_QENV_PREV_PWD` | `$PWD` as of the last sync (for change detection) |
| `_QENV_FOUND_ENTER` | The path to the `qenv.enter` found by `_qenv_find` (empty = none) |
| `_QENV_ACTIVE_ENTER` | The path to the currently active `qenv.enter` |
| `_QENV_DISABLED` | Non-empty = frozen: syncing as well as enter/leave/reload are stopped (toggled with `qenv disable` / `qenv enable`, §9). Not exported, confined to that shell |
| `_QENV_DIFF_BASE` (associative array) | Temporary, during an enter. The snapshot of the exports before the source. Not exported |
| `_QENV_EDIT_PIDS` / `_QENV_EDIT_TARGETS` / `_QENV_EDIT_BEFORES` (parallel arrays) | The watch lists for edits deferred by ^Z (the editor's PID, the target path, the mtime before the edit; §9) |
| `_QENV_BUSY` (local) | The re-entry guard. Visible to callees through dynamic scoping only while qenv is running (§5) |
| `_QENV_ENTERING` (exported) | The exec-detection marker, set only while sourcing an enter (§5, the exec loop guard). Unset on completion |
| `_QENV_SKIP_ENTER` | The path to a `qenv.enter` whose auto-enter is suppressed by the exec loop guard (empty = none). Lifts itself on a completed enter |
| `_QENV_PRETTY` | Where `_qenv_pretty` leaves its result. A display-only path with a leading `$HOME/` shortened to `~/` (passed by variable to avoid a fork) |
| `_qenv_restore` (function) | The diff-based restore function. Always called on leave |

### Initialization at load time

At load time, `qenv.sh` decides `QENV_ROOT`, creates it with mode 700 if absent, and defines the
state
variables as empty.

```bash
: "${QENV_ROOT:=${XDG_CONFIG_HOME:-$HOME/.config}/qenv}"   # default if unset
QENV_ROOT="${QENV_ROOT%/}"                                  # normalize a trailing slash (avoids //)
[[ -d $QENV_ROOT ]] || { mkdir -p "$QENV_ROOT" && chmod 700 "$QENV_ROOT"; }  # create it with 700 (yours alone) if absent
: "${_QENV_PREV_PWD=}" "${_QENV_FOUND_ENTER=}" "${_QENV_ACTIVE_ENTER=}" "${_QENV_DISABLED=}"  # define empty (safe under set -u and on re-source)
: "${_QENV_SKIP_ENTER=}"
if [[ -n ${_QENV_ENTERING:-} ]]; then        # a shell started in the middle of an enter → the exec loop guard (§5)
  _QENV_SKIP_ENTER=$_QENV_ENTERING
  unset -v _QENV_ENTERING
  _qenv_pretty "$_QENV_SKIP_ENTER"             # shorten a leading $HOME/ to ~/ for display (§10)
  printf 'qenv: this shell was started while entering %s\n' "$_QENV_PRETTY" >&2
  printf 'qenv: (exec or a new shell inside qenv.enter?) auto-enter of that file is suppressed to break a loop\n' >&2
fi
# The watch list for ^Z-deferred edits. If they are already arrays, leave them alone (pending entries survive a re-source); otherwise define them as empty arrays
case $(declare -p _QENV_EDIT_PIDS 2>/dev/null) in 'declare -a'*'=('*) ;; *) unset -v _QENV_EDIT_PIDS; declare -ga _QENV_EDIT_PIDS=() ;; esac
# (_QENV_EDIT_TARGETS and _QENV_EDIT_BEFORES likewise)
```

- **The state variables are defined as empty** so that the first sync does not die on an "unbound
  variable" under `set -u` (nounset).
  The `: "${VAR=}"` form does not clobber values that are already set. **Even if you re-source
  `qenv.sh` in a shell you are working in**, the active
  environment and the ^Z-pending entries stay alive.
- **`_QENV_DISABLED` uses the same `: "${VAR=}"` form**, so re-sourcing `qenv.sh` while disabled
  keeps it disabled.
  At the same time, because that variable is not `export`ed, it is not inherited by new shells: **a
  new shell always starts enabled** (§9).
- The watch lists are not defined with an "attributes only" `declare -a`. An array with no value
  makes `${#arr[@]}` an unbound error under `set -u`, so the `=()` is always written out.
- If `_QENV_ENTERING` is present at load time, this shell was exec'd or started in the middle of an
  enter.
  To break the infinite loop, auto-entering that file is suppressed (§5, the exec loop guard).
- **`QENV_ROOT` is created with 700** so that a fresh environment satisfies §11's "only you can
  write to `~/.config/qenv`" from the start.
  It is only created when absent, though; the permissions of an existing directory are not changed
  (not using it with loose permissions is the user's responsibility, §11).

---

## 11. Security: what is and is not protected

### Protected: leaking into git

qenv's purpose is to quarantine secrets outside your repositories and **prevent leaks into git**.
`qenv.enter` lives under `~/.config/qenv` and never enters a repository.

### The assumption: only you can write to `~/.config/qenv`

Sourcing `qenv.enter` is arbitrary code execution. qenv has no equivalent of `direnv allow`.
Security therefore rests on the assumption that "only you
can write to `~/.config/qenv`". These points are stated explicitly:

- Keep `~/.config/qenv` (and `$HOME`) in a mode others cannot write to.
- If your home directory sits on a shared machine or is synced somewhere with loose permissions,
  whoever can write there can execute arbitrary code.
- qenv trusts the location. Trust in the location
  translates directly into trust in what gets executed.

`qenv.sh` creates `QENV_ROOT` with mode 700 (yours alone) the first time, so a fresh environment
satisfies this assumption automatically (§10). It does not change the permissions of an existing
directory, however, so not using it with loose permissions is the user's responsibility.

A file-permission policy (such as "refuse a `qenv.enter` that is group/other writable") is
**not implemented**, because it would duplicate the trust model above. Write control is
left to ordinary file permissions.

### Not protected: malware running as the same user

qenv does not defend against malware or an RCE running
as the same user. `qenv.enter` is plaintext, so
anyone who can read `~/.config` can take the secrets.
This is a limitation shared by every tool that handles plaintext secrets — `.env`, `~/.aws`,
direnv — and it belongs to the OS's domain.

The restore information is not encrypted either. As long as `qenv.enter` is plaintext, encryption
would not be a real defense.

If you do want to prepare for this threat, the direction is not encryption but "do not keep
plaintext
in `~/.config`". Since `qenv.enter` can contain arbitrary shell code, you can fetch secrets from a
secret manager at enter time, as in `export TOKEN=$(op read ...)`.
No configuration change is required.

---

## 12. Caveats

- **It only applies automatically in interactive shells.** `qenv` runs from PROMPT_COMMAND.
  It does not fire automatically under cron, in CI, or in scripts. To apply it inside a script, `cd`
  to the directory you want and call `qenv` directly.
  Sourcing `qenv.enter` directly is not recommended, since it bypasses the find and the rollback.
- **There is no automatic leave when the shell exits.** The automatic leave runs only at the first
  prompt after a `cd` to another directory, not on `exit` or `kill`.
  If you need cleanup at exit too, install `trap qenv-leave EXIT` in `qenv.enter` (§6).
- **Do not use `qenv-leave` to stop shared resources.** `qenv-leave` runs only in **the shell that
  left**.
  Even if the same `qenv.enter` is in effect in two
  terminals, leaving in one runs only that terminal's
  `qenv-leave`.
  So using it to clean up **shared resources** — stopping a server, unmounting, releasing a lock —
  will disrupt other terminals that are still using them. Write only cleanup that is
  self-contained within that shell.

---

## Appendix: comparison with direnv

These points are the same as direnv.

- Exactly one `.envrc` is in effect: the nearest ancestor
  of where you are. It does not depend on the route.
- Parents are not inherited automatically. If a child has an `.envrc`, the parent's does not apply.
- The rollback is the inverse application of a single diff. There is no stack.
- Only exported scalar variables are covered. Functions, arrays, and aliases are not handled.

qenv differentiates itself in four ways.

1. It quarantines `qenv.enter` outside the repository, preventing leaks into git.
2. No `direnv allow` equivalent approval is needed.
3. It needs no dedicated binary; it sources directly into the current shell. Bare variables work too.
4. It can have a leave hook, `qenv-leave` (direnv has none).

The reason direnv has no **custom leave-time handling** (no `qenv-leave` equivalent) is that it
evaluates things differently.
direnv evaluates `.envrc` **in a subshell** and imports only the resulting environment variable diff
into the interactive shell.
Functions defined by `.envrc` do not remain in the interactive shell, so there is no cleanup hook to
call on the way out in the first place.
qenv **sources `qenv.enter` directly into the interactive shell**, so the `qenv-leave` function
remains and can be called on the way out.
The caveats in §12 (do not use it for shared resources, and so on) still apply, though.
