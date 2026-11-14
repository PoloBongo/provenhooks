# stop-gate

Replays your project's checks when Claude finishes a turn — and, crucially,
stays out of the way when nothing has changed.

*Verified against Claude Code 2.1.323. Covered by 51 tests (`test.sh`).*

## Why

A `Stop` hook fires at the end of **every** turn, including the ones where you
only asked a question. The naive version re-runs your whole test suite each
time, times out, and silently stops protecting you — a hook that exceeds its
timeout is cancelled, its output discarded, and the turn ends as if it had
passed.

`stop-gate` fingerprints the working tree and does nothing until it moves.

## Configure

`.claude/stop-gate.conf`, one rule per line:

```
# mode   glob                command
fix      resources/**        npx prettier --write
check    **/*.ts             npm run types
check    **/*.php            vendor/bin/pint --test --dirty
```

- **`fix`** — mechanical. The matching changed files are appended to the
  command and it is applied. It only blocks if the command itself fails.
- **`check`** — a gate. Runs when a matching file changed; a non-zero exit
  blocks the turn. All `check` rules run in parallel.

`**` spans directories, `*` does not.

## Install

```jsonc
// .claude/settings.json
{ "hooks": { "Stop": [{ "matcher": "", "hooks": [
    { "type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/stop-gate.sh\"", "timeout": 300 }
]}]}}
```

## What it does

| | |
| --- | --- |
| Nothing changed since the last verdict | Exits immediately, runs nothing |
| A formatter would complain | Runs it instead of reporting it |
| A gate fails | Exits 2 once, with the failing command and its output on stderr |
| The same failure, next turn | Stays quiet — it was already said, and CI is the net |
| Timings | `.git/stop-gate.log`, last 200 runs |
| Force a re-run | `rm .git/stop-gate.sig` |

## Known limits

- Needs `git`; outside a repository it exits 0 and does nothing.
- The fingerprint hashes every changed file. On a tree with thousands of
  uncommitted files, that is not free.
- `check` commands run through `eval`, so the config file is executable code.
  Treat it like any other file in your repo.
