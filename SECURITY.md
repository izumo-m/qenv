# Security Policy

qenv is a personal project maintained in my spare time, free of charge. Everything below is
best-effort: there are no guaranteed response times, fixes, or support periods.

## Supported versions

Fixes, when made, go into the latest release only. Please check that the issue still reproduces
with the latest version before reporting.

## Reporting a vulnerability

**Please do not open a public issue.** Report it privately via
[GitHub private vulnerability reporting](https://github.com/izumo-m/qenv/security/advisories/new).

Please include:

- qenv version (or commit), bash version, and OS
- steps to reproduce, and what you expected vs. what happened
- the impact as you see it

I will try to respond and, where appropriate, release a fix and publish an advisory, but I cannot
promise when. Reporters are credited in the advisory unless they prefer otherwise.

## Scope

qenv's trust model is described in
[docs/spec.md §11](docs/spec.md#11-security-what-is-and-is-not-protected).
In short: sourcing `qenv.enter` is arbitrary code execution by design, and qenv trusts that only
you can write to `QENV_ROOT`.

**In scope** — for example:

- Code execution triggered by something other than your own `qenv.enter`
  (e.g. a crafted directory name in a cloned repository injecting code when you `cd` into it)
- qenv sourcing a `qenv.enter` other than the one the lookup rules (§4) select
- qenv exposing secrets beyond what `qenv.enter` itself does
  (e.g. leaking restore data into child processes, or failing to roll back on leave)
- qenv creating `QENV_ROOT` or new `qenv.enter` files with permissions looser than 700 / 0600

**Out of scope:**

- Anything a `qenv.enter` you wrote does when sourced
- Secrets being stored in plaintext under `QENV_ROOT`
- Attackers who can already write to `QENV_ROOT` or `$HOME`, or run code as your user
- Misbehavior caused by other tools in `PROMPT_COMMAND`
