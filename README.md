# qenv

**qenv is a direnv-like manager that quarantines environment variables outside your repositories.**
Enter a directory and its environment variables are loaded; leave it and they are rolled back. The
configuration file (`qenv.enter`) does not live in your working directory — it lives under
`~/.config/qenv`, so secrets (API keys, tokens, and the like) do not find their way into git.

This document explains how to use qenv. For the design rationale and internals, see
[`docs/spec.md`](docs/spec.md).

---

## Install

qenv is a single file, `qenv.sh`. Clone the repository anywhere you like:

```bash
git clone https://github.com/izumo-m/qenv.git
```

There is nothing to build or install: `qenv.sh` is sourced from your `.bashrc`, as shown below. The
rest of the repository is documentation.

---

## Setup

Source `qenv.sh` from your `.bashrc` and register it with `PROMPT_COMMAND`.

```bash
# ~/.bashrc
source /path/to/qenv.sh
PROMPT_COMMAND=qenv
```

- Sourcing creates the configuration root `~/.config/qenv`
  (`QENV_ROOT`) if it does not exist, with mode 700.
- `PROMPT_COMMAND=qenv` runs `qenv` at every prompt. Normally it loads or
  rolls back only at the moment you change directory. The one exception is a
  `qenv edit` you suspended with ^Z, which is applied once the editor exits.
- If you already use `PROMPT_COMMAND`, see [Sharing `PROMPT_COMMAND` with other
  tools](#sharing-prompt_command-with-other-tools).

qenv requires **bash 5.x** (4.x at the very least).

---

## Quick start

```bash
cd ~/myproject
qenv edit                 # if new, confirm (create …? [y/N]); y opens $EDITOR. Write this and save.
```

```bash
# ~/.config/qenv/home/you/myproject/qenv.enter  (the file qenv edit opens)
export DATABASE_URL=postgres://localhost/myproject_dev
export API_TOKEN=dev-xxxxxxxx
```

Save and close, and it takes effect at the next prompt.

```bash
echo "$API_TOKEN"          # dev-xxxxxxxx
cd ..                      # leave myproject
echo "${API_TOKEN:-unset}" # unset (rolled back)
```

The variables apply only while you are inside `myproject`, and disappear when you leave.

---

## What to put in qenv.enter

On entry, qenv sources `qenv.enter` into your current shell (plain bash; `$@` is always empty).
**Only exported scalar variables are rolled back** — that is the one rule specific to qenv.

### 1. Environment variables (`export`)

**Rolled back when you leave.**

```bash
export AWS_PROFILE=dev
export DATABASE_URL=postgres://localhost/dev
```

- A newly exported variable → `unset` when you leave.
- A pre-existing variable you changed → restored to its old value when you leave.

### 2. Temporary variables (bare, no `export`)

Not passed to child processes, and **not rolled back** (they survive after you leave).

```bash
base=/opt/app                       # intermediate value, not leaked to children
export PATH="$base/bin:$PATH"        # the exported one is what you use
```

Since they are not rolled back, if you put a secret in a temporary variable, `unset` it yourself at
the end of `qenv.enter`.

### 3. Leave hook (the `qenv-leave` function)

If you define a function named `qenv-leave`, it is called when you leave the directory.
It **runs before the rollback**, so it can still read the variables that `qenv.enter` exported.

```bash
eval "$(ssh-agent -s)"               # exports SSH_AGENT_PID and friends
qenv-leave() { ssh-agent -k; }       # stop the agent when you leave (SSH_AGENT_PID is still readable)
```

Use it to stop processes, shut down servers, or otherwise clean up. If you do not define it, only
the
rollback runs when you leave.

### 4. Other commands (`cd`, `trap`, …)

Commands other than `export` run as written and are not rolled back.

```bash
trap qenv-leave EXIT                 # also run qenv-leave when the shell exits (see the caveat below)
```

The same goes for `cd`, `set`, `shopt`, and so on (for the ones with large side effects, see
"What not to write" below).

### What not to write

These break the premise that the file is sourced into your current shell on every `cd`.

- **`exec`, and external commands that run `$SHELL` / `exec $SHELL`** … they
  replace your current shell and never return control — whether you write the
  `exec` yourself, or an external command that `qenv.enter` calls runs it.
- **`exit`** … terminates the shell (it closes the moment you enter).
- **A `cd` that does not come back** … the move itself is not rolled
  back. If it lands you where a different `qenv.enter` applies — or where
  none applies — the file you just entered is left at the next prompt.
- **Shell options such as `set -e` / `-u` / `-x`** … they stay in the shell and are not rolled back.
- **Anything that waits for input or occupies the foreground** (`read`, a foreground server,
  …) … your shell hangs on every `cd` (push such work into the background with `&`).

### Scope and rollback caveats (`declare`, `local`, arrays, `readonly`)

- **`local`, `declare` / `typeset` (without `-g`)** … `qenv.enter` is sourced inside one of qenv's
  internal functions, so these last only for the duration of the entry and do not remain in your
  shell. To make them stick, use a bare assignment, `export`, or `declare -g`.
- **Arrays** … they remain in the shell, but they are not exported and therefore not rolled back.
- **`readonly`** … cannot be rolled back (if you mark an exported variable readonly, restoring it
  when you leave fails).

---

## Commands

| Command | What it does |
|---|---|
| `qenv` | Evaluate the current directory and load or roll back. The main entry point, called from `PROMPT_COMMAND` (you can also run it by hand) |
| `qenv status` | Show the path of the active `qenv.enter` and whether `qenv-leave` is defined |
| `qenv edit [DIR]` | Open DIR's `qenv.enter` in `$EDITOR`, creating it if absent (DIR defaults to the current directory) |
| `qenv enable` | Unfreeze, then re-check the current directory and roll back / load if anything changed |
| `qenv disable` | Freeze (safe mode). Stops syncing as well as entering, leaving, and reloading. The current environment is left as is |
| `qenv reload` | Force the nearest `qenv.enter` to be rolled back and re-loaded (a no-op while disabled) |
| `qenv help` | Show usage |

### `qenv status`

```console
$ qenv status
active:     ~/.config/qenv/home/you/myproject/qenv.enter
qenv-leave: defined
```

If nothing is active, it prints `active: (none)`. If a `qenv edit` is pending because you suspended
the editor with ^Z, one `edit wait: <path to qenv.enter>` line is printed per pending edit.
If auto-loading of some `qenv.enter` has been suppressed because qenv detected that the shell
had been replaced by `exec`, a `suppressed: <path> (exec loop guard)` line is printed as well.
While syncing is stopped by `qenv disable`, a `state: disabled` line appears at the top.

### `qenv edit [DIR]`

- Omit DIR to edit the current directory's `qenv.enter`. You can also name another directory, as in
  `qenv edit /etc`.
- **A non-existent DIR is an error** (`qenv: no such directory`). This is the guard against typos.
- **You are asked for confirmation only when `qenv.enter` does not exist yet** (`create …? [y/N]`,
  defaulting to No). Existing files open immediately, without confirmation.

```console
$ qenv edit ~/newproject
qenv: create ~/.config/qenv/home/you/newproject/qenv.enter? [y/N] y
```

- New files are created with mode 0600 (readable and writable only by you), and the mirrored
  directories with mode 0700.
- The editor is `$EDITOR` (`vi` if unset). Editors with
  arguments, such as `EDITOR="code --wait"`, work too.
- **Saving applies the change immediately, as long as the file you edited is the one that applies
  where you are.** That includes editing the `qenv.enter` that is currently active — save, and it is
  re-loaded at once. Editing the `qenv.enter` of some other directory saves the file but changes
  nothing here. If you only open it and do not save, nothing changes.
- **Suspending with ^Z is safe.** If you stop the editor with ^Z, applying the change is deferred
  (you will see `qenv: editor stopped; reload deferred …`). Bring it back with `fg`, save and quit,
  and the change is applied at the next prompt. If you quit without saving, nothing changes.
  You can stack suspended edits of different `qenv.enter` files; each is tracked independently.
  Pending edits are listed on the `edit wait:` lines of `qenv status`.

### `qenv disable` / `qenv enable`

Use these when you want to stop automatic syncing for a while. `disable` is a **freeze (safe
mode)**:
while frozen, no `qenv.enter` is read at all.

**`qenv disable` (freeze)**

- Stops automatic syncing. Nothing happens when you `cd` or when the prompt advances.
- **No `qenv.enter` is loaded (no entering) and nothing is rolled back (no leaving).** The
  environment variables currently in effect are frozen as they are.
- You can still open, edit, and save files with `qenv edit`, but the contents are not applied
  (`qenv reload` does nothing either).
- `qenv status` shows `state: disabled`.

**`qenv enable` (unfreeze)**

- Lifts the freeze and resumes automatic syncing.
- At the same time it re-checks the current directory. If the **path** of the `qenv.enter` that
  should apply has changed, it rolls back and loads on
  the spot. If it has not changed, nothing happens.
- When you have only fixed the **contents** of the same file, the path is unchanged, so `enable`
  does not apply it. Follow up with `qenv reload`.

```bash
qenv disable          # until you re-enable, the environment is frozen wherever you cd and whatever you edit
# … move around freely, work on another project, and so on …
qenv enable           # unfreeze; roll back / load again to match where you now are
```

`disable` applies **only within that shell**. New shells always start enabled (and re-sourcing
`qenv.sh` in the same shell preserves the disabled state).

#### Recovering from a broken `qenv.enter` (safe mode)

When a mistake in `qenv.enter` has broken your environment, the safe way is to freeze with `disable`
and then fix it. While frozen, the broken file is not re-read, so you do not make things worse.

```bash
qenv disable          # freeze (leave the broken environment alone, touch nothing further)
qenv edit             # fix it (saving does not apply it while disabled)
qenv enable           # unfreeze
qenv reload           # re-read the fixed qenv.enter and recover
```

### `qenv reload`

**Forces a rollback and re-load** of the `qenv.enter` that applies where you are (if one is active,
it is left first, then entered again). Use it when you have edited `qenv.enter`
by hand instead of through `qenv edit`, and want it applied without moving.

```bash
$EDITOR ~/.config/qenv/home/you/myproject/qenv.enter   # edit directly by hand and save
qenv reload                                            # apply without moving
```

**While disabled, `qenv reload` does nothing** (this keeps the promise that a
freeze reads no `qenv.enter`). Run `qenv enable` first, then `qenv reload`.

---

## How it works

### Where files live: the mirror tree

`qenv.enter` is stored at a location that mirrors the path of the working directory.

| Working directory | Location of qenv.enter |
|---|---|
| `/home/you/work` | `~/.config/qenv/home/you/work/qenv.enter` |
| `/etc` | `~/.config/qenv/etc/qenv.enter` |
| anywhere (the default) | `~/.config/qenv/qenv.enter` |

Since nothing is placed in the working directory, you can apply settings even to directories you
cannot write to, such as `/etc`.

### When it applies

- **Entering loads.** When you `cd` into a directory (or
  any of its descendants), its `qenv.enter` is sourced.
- **Leaving rolls back.** When you `cd` to a place where
  no `qenv.enter` applies, `qenv-leave` (if defined)
  is called and the exported variables are restored.
- **Exactly one — the nearest ancestor — applies.** qenv walks up from the current directory and
  uses the first `qenv.enter` it finds.
  Nested `qenv.enter` files do not stack. Only one is ever in effect.
  To inherit a parent's settings, source it explicitly (see
  [Inherit a parent's `qenv.enter`](#inherit-a-parents-qenventer)).
- **It does not depend on how you got there.** Which `qenv.enter` applies is determined solely by
  where you are now. Symlinks are normalized to their real paths.

```bash
cd /home/you/work          # work/qenv.enter applies
cd /home/you/work/sub      # switches to sub/qenv.enter if it exists (work's is rolled back)
cd /tmp                    # neither applies → roll back, nothing in effect
```

### What gets rolled back

Only **exported environment variables** are rolled back. Temporary (bare) variables, functions, and
arrays are out of scope and survive after you leave. This is the same trade-off direnv makes.

If there are exported variables you do not want rolled back, list them in `QENV_KEEP`, separated by
whitespace (globs allowed).

```bash
QENV_KEEP='KUBECONFIG AWS_*'    # globally, in ~/.bashrc. You can set or change it at any time
```

To keep something only in a particular environment, export it from within `qenv.enter`.

```bash
# qenv.enter
export QENV_KEEP=DATABASE_URL     # DATABASE_URL survives leaving this environment
export DATABASE_URL=postgres://localhost/dev
```

`QENV_KEEP` itself is a newly exported variable, so it disappears when you leave and does not spill
over
into other environments.

---

## Recipes

### A project-specific PATH

```bash
export PATH="/home/you/myproject/node_modules/.bin:$PATH"
```

> Absolute paths are the reliable choice. `$PWD` is wherever you just `cd`-ed to, so if you enter
> from a subdirectory it will not point at the project root.

### Inherit a parent's `qenv.enter`

Nested `qenv.enter` files do not stack, so a child's replaces its parent's. To build on the parent,
source it from the child. The mirror tree keeps the parent's file right above your own, so a path
relative to `BASH_SOURCE` finds it wherever `QENV_ROOT` lives.

```bash
# ~/.config/qenv/home/you/work/sub/qenv.enter
source "${BASH_SOURCE%/*}/../qenv.enter"       # work/qenv.enter (one level up)
# source "${BASH_SOURCE%/*}/../../qenv.enter"  # two levels up, and so on
export STAGE=sub                               # then add or override
```

- Everything the parent exports is part of the child's diff, so it is rolled back on leave too.
- If the parent sources its own parent the same way, the chain continues upward.
- `qenv-leave` is a single function: if both files define it, the one defined last (the child's)
  wins. Put the cleanup for both into the child's `qenv-leave`.
- Editing the parent with `qenv edit` while you are inside the child does not apply it
  automatically (the child is the nearest one). Run `qenv reload`.
- If the parent's file is missing, `source` fails loudly on stderr rather than being skipped.

### Start ssh-agent, and stop it when you leave

```bash
eval "$(ssh-agent -s)" >/dev/null
ssh-add ~/.ssh/project_key 2>/dev/null
qenv-leave() { ssh-agent -k >/dev/null; }    # runs before the rollback, so SSH_AGENT_PID is readable
```

### Start a dev server, and stop it when you leave

```bash
export DB_URL=postgres://localhost/dev
_server_pid=$(start-dev-server >/dev/null 2>&1 & echo $!)   # bare: not leaked to children, not rolled back
qenv-leave() { kill "$_server_pid" 2>/dev/null; }
```

### Clean up on shell exit too

The automatic rollback runs at the first prompt after you `cd` elsewhere. It does not run when you
`exit` or close the window. To cover that too, install a `trap`.

```bash
qenv-leave() {
  kill "$_server_pid" 2>/dev/null
  trap - EXIT          # avoid running twice
}
trap qenv-leave EXIT   # qenv-leave runs both when you cd away and when you exit
```

---

## Configuration

| Variable | Purpose |
|---|---|
| `QENV_ROOT` | Where configuration lives. Default: `${XDG_CONFIG_HOME:-$HOME/.config}/qenv` |
| `QENV_QUIET` | Non-empty: suppress the load / rollback notifications |
| `QENV_KEEP` | Exported variables never rolled back. Whitespace-separated, globs allowed (e.g. `'KUBECONFIG AWS_*'`) |

To change `QENV_ROOT`, set it **before** sourcing `qenv.sh`.

```bash
# ~/.bashrc
export QENV_ROOT=$HOME/.qenv
source /path/to/qenv.sh
PROMPT_COMMAND=qenv
```

### Notifications

By default, one line goes to standard error on each load and rollback.

```text
qenv: enter ~/.config/qenv/home/you/work/qenv.enter   # when you enter
qenv: leave ~/.config/qenv/home/you/work/qenv.enter   # when you leave
```

For readability, a leading `$HOME/` is shortened to `~/` in the displayed path (display only — the
real path stays absolute). To stop the notifications, set `QENV_QUIET=1`.
When you have not moved, nothing is printed in the first place.

### Sharing `PROMPT_COMMAND` with other tools

If you already use `PROMPT_COMMAND`, add qenv **by assignment, not by string concatenation**.

```bash
PROMPT_COMMAND='qenv; __git_ps1'
```

String concatenation (`PROMPT_COMMAND="$PROMPT_COMMAND; qenv"`) breaks the array form of
`PROMPT_COMMAND` in bash 5.1+, so avoid it.

---

## Security

- **Credentials are stored in plaintext. Keeping them unreadable by others is what matters most.**
  `qenv.enter` files often contain API keys and tokens in the clear, so keep `~/.config/qenv` (and
  `$HOME`) **unreadable by anyone but you**. qenv creates `QENV_ROOT` with mode 700 and new
  `qenv.enter` files with mode 0600. Avoid putting your home directory on a shared machine or
  syncing it somewhere with loose permissions.
- **There is no encryption.** Anyone who can read `~/.config/qenv` can read the contents (a
  limitation shared by every tool that handles plaintext — `.env`, `~/.aws`, direnv, and so on).
- **Nothing ends up in git.** This is qenv's main purpose. `qenv.enter` lives outside your
  repository, so `git add` cannot sweep it in.

---

## Caveats

- **It only applies to interactive shells.** `qenv` runs from `PROMPT_COMMAND`. It does not fire
  automatically under cron, in CI, or in scripts.
  To apply it inside a script, `cd` to the directory you want and call `qenv` directly.
- **There is no automatic rollback when the shell exits.** If you need cleanup at exit, use
  `trap qenv-leave EXIT` (see the recipe above).
- **`qenv-leave` runs only in the shell that left.** Even if the same `qenv.enter` is in effect in
  two terminals, leaving in one runs only that terminal's hook.
  So using it to clean up **shared resources** — stopping a server, unmounting, releasing a lock —
  will disrupt other terminals that are still using them.
  Write only cleanup that is self-contained within that shell.
- **Temporary (bare) variables survive after you leave.**
  If you put a secret in one, `unset` it yourself.

---

## Troubleshooting

- **I edited it but nothing happened.** If you created it with `qenv edit`, it applies at the next
  prompt. If you placed `qenv.enter` by hand, either run `qenv reload` to re-read it on the spot, or
  leave the directory and come back (movement is the trigger).
- **I want to check whether it is active.** Run `qenv status`.
- **I want to stop it for a while / my environment is broken.** Freeze with `qenv disable` (no
  `qenv.enter` is read), then after fixing it, `qenv enable` → `qenv reload` if
  needed (see [safe mode](#recovering-from-a-broken-qenventer-safe-mode) above).
- **The notifications are noisy.** Set `QENV_QUIET=1`.
- **My editor does not open / I want a different one.** Set `EDITOR` (e.g. `export EDITOR=nvim`).
  Without it, `vi` is used.
- **I get `qenv: requires bash 4+` when sourcing.** bash 4.x
  or later is required. Check with `echo "$BASH_VERSION"`.

---

## License

[MIT](LICENSE)
