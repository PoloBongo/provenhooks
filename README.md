# provenhooks

[![tests](https://github.com/PoloBongo/provenhooks/actions/workflows/test.yml/badge.svg)](https://github.com/PoloBongo/provenhooks/actions/workflows/test.yml)

Claude Code hooks that ship with their test harness — and the harness itself,
so you can point it at your own.

```bash
/plugin marketplace add PoloBongo/provenhooks
/plugin install provenhooks@provenhooks
```

> Hooks for Claude Code, not webhooks.

## Why this exists

A hook is a program: JSON in on stdin, an exit code out, stderr as the message.
That is eminently testable. Almost nobody tests it.

Look through the public collections of Claude Code hooks and you find plenty
to copy, and almost nothing that proves any of it runs. No suites, no CI.

Here is what that costs, from this repository's own history. The first version
of `stop-gate` was green on Linux and broken on macOS, where `/bin/bash` is
still 3.2: its parser counts parentheses inside a command substitution without
regard for quoting, so the one closing a `case` pattern ended the substitution
early. The hook exited 1 having run nothing — no checks, no message, turn over.
`shellcheck` is silent on it, and so is every Linux machine. A test matrix
found it in four minutes.

That gap matters because a hook fails *silently*. A `Stop` hook that overruns
its timeout is cancelled and its output discarded — the turn ends as though
every check had passed. A hook that ignores `stop_hook_active` blocks forever.
One with an unbound variable exits non-zero for a reason that has nothing to do
with your code. You find out in review, or you never find out.

So every hook here comes with three things:

1. **A test suite** you can run in one command.
2. **A stamp** naming the Claude Code version it was verified against.
3. **A CI job** that re-runs the suites weekly, so a release that breaks a hook
   shows up as a red build rather than as your bad afternoon.

## What's in it

| Hook | Event | What it does | Tests |
| --- | --- | --- | --- |
| [stop-gate](hooks/stop-gate/) | `Stop` | Replays your project's checks, applies the mechanical fixes, and stays quiet when nothing changed | 61 |

## Test your own hooks

This is the part worth having even if you use none of the hooks above.

### The contract

One line tells you whether a hook — yours, mine, or one you copied off a blog —
holds up:

```bash
source lib/harness.sh
ph_contract path/to/your-hook.sh --event Stop
ph_summary
```

It checks that the hook exits cleanly when it has already blocked once, that it
does not block a tree nobody touched, that it survives empty and malformed
input, that it does not hang, that it stays inside its time budget, that it
cleans up after itself, and that its exit code means what it appears to mean.
Smells — writing to a stdout nobody reads, exiting 1 when you meant to block —
come back as warnings rather than failures.

`lib/fixtures/` holds six hooks that are deliberately wrong, one per defect, so
the contract is itself tested against things it must catch.

### The harness

For behaviour the contract cannot know about, write ordinary cases. Each one
gets a disposable git repository and stubbed commands:

```bash
source lib/harness.sh

ph_repo                                   # fresh git repo, cd'd into
ph_stub npm --exit 1 --out "type error"   # a fake npm on PATH
echo 'export const a = 1' > a.ts

ph_run hooks/stop-gate/stop-gate.sh '{"stop_hook_active":false}'

ph_eq       "blocks the turn"    2 "$RC"
ph_contains "names the command"  "$ERR" "npm run types"
ph_true     "ran it once"        "ph_called npm"

ph_summary
```

| | |
| --- | --- |
| `ph_repo` | Fresh git repo for this case, seeded and committed |
| `ph_stub NAME [--exit N] [--out TEXT] [--sleep S] [--writes F:TEXT]` | A fake command on `PATH` that records how it was called |
| `ph_run HOOK [JSON]` | Runs the hook; sets `$RC`, `$OUT`, `$ERR`, `$DUR` |
| `ph_contract HOOK [--event NAME] [--budget S]` | The contract above |
| `ph_called NAME` / `ph_calls` / `ph_ncalls` | What the hook invoked, and how |
| `ph_concurrency NAME` | How many ran at once — parallelism without timing the runner |
| `ph_nlines` | Lines on stdin, unpadded, so the count compares equal on BSD too |
| `ph_eq` `ph_contains` `ph_lacks` `ph_true` `ph_false` | Assertions |
| `ph_summary` | Prints the tally, exits non-zero if anything failed |

Zero dependencies beyond `bash` and `git`. Runs in Git Bash on Windows, which
is where a fair share of these hooks actually execute.

## Run the tests

```bash
bash lib/test.sh                                  # the harness and the contract
bash hooks/stop-gate/test.sh                      # one hook
for t in hooks/*/test.sh; do bash "$t"; done      # all of them
```

## Contributing a hook

A pull request adding a hook is welcome when it brings a `test.sh` that passes
and calls `ph_contract`, a `README.md` saying what it does and what it does
**not** cover, and the Claude Code version it was verified against. A hook
without tests is the thing this repository exists to argue against, so those
are declined — with an offer to help write them.

## Licence

MIT.
