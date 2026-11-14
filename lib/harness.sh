#!/usr/bin/env bash
# provenhooks harness — a test harness for Claude Code hooks.
#
# A hook is just a program: JSON on stdin, an exit code out, stderr as the
# message. That is testable, and almost nobody tests it. This harness gives
# each case a disposable git repository, stubbed commands, and assertions
# about what the hook did.
#
#   source lib/harness.sh
#   ph_repo                                  # disposable git repo, cd'd into
#   ph_stub npm --exit 1 --out "boom"        # fake command on PATH
#   ph_run hook.sh '{"stop_hook_active":false}'
#   ph_eq "blocks" 2 "$RC"
#   ph_summary                               # exits non-zero if anything failed
#
# Zero dependencies beyond bash and git. Works in Git Bash on Windows.

set -u

PH_PASS=0
PH_FAIL=0
PH_WARN=0
PH_ROOT="$(mktemp -d)"
PH_STUBS="$PH_ROOT/stubs"
mkdir -p "$PH_STUBS"
export PATH="$PH_STUBS:$PATH"
export PH_CALLS="$PH_ROOT/calls.log"
export PH_SEQ="$PH_ROOT/seq.log"

_ht_cleanup() { cd /; rm -rf "$PH_ROOT"; }
trap _ht_cleanup EXIT

# --- assertions ---------------------------------------------------------
_ht_ok()   { PH_PASS=$((PH_PASS+1)); printf '    ok   %s\n' "$1"; }
_ht_ko() {
  PH_FAIL=$((PH_FAIL+1)); printf '    FAIL %s\n' "$1"
  [ -n "${2:-}" ] && printf '         %s\n' "$2"
  # A hook that dies says why on stderr. Swallowing it here is how a portability
  # bug becomes "exit 1, no idea" on a machine you don't have.
  if [ -n "${ERR:-}" ] && [ "${ERR:-}" != "${PH_ERR_SHOWN:-}" ]; then
    printf '%s\n' "$ERR" | sed -n '1,8p;9s/.*/         .../p' | sed 's/^/         stderr| /'
    PH_ERR_SHOWN="$ERR"
  fi
  return 0
}

_ht_warn() { PH_WARN=$((PH_WARN+1)); printf '    warn %s\n' "$1"; [ -n "${2:-}" ] && printf '         %s\n' "$2"; }

ph_case() { printf '  %s\n' "$1"; }

ph_true() { # ph_true <description> <shell expression>
  if eval "$2"; then _ht_ok "$1"; else _ht_ko "$1" "expression fausse : $2"; fi
}
ph_false() { if eval "$2"; then _ht_ko "$1" "expression vraie : $2"; else _ht_ok "$1"; fi; }

ph_eq() { # ph_eq <description> <expected> <actual>
  if [ "$2" = "$3" ]; then _ht_ok "$1"; else _ht_ko "$1" "attendu [$2], obtenu [$3]"; fi
}

ph_contains() { # ph_contains <description> <haystack> <needle>
  case "$2" in *"$3"*) _ht_ok "$1" ;; *) _ht_ko "$1" "ne contient pas [$3]" ;; esac
}

ph_lacks() {
  case "$2" in *"$3"*) _ht_ko "$1" "contient [$3] alors qu'il ne devrait pas" ;; *) _ht_ok "$1" ;; esac
}

# --- disposable repository ----------------------------------------------
ph_repo() { # ph_repo [name] -> fresh git repo, cd'd into, with one commit
  local d="$PH_ROOT/repo-${1:-$RANDOM}"
  rm -rf "$d"; mkdir -p "$d"; cd "$d" || return 1
  git init -q .
  git config user.email t@example.invalid
  git config user.name  provenhooks
  git config core.autocrlf false
  printf 'seed\n' > .seed
  git add -A && git commit -qm seed
  : > "$PH_CALLS"; : > "$PH_SEQ"
}

# --- stubbed commands ----------------------------------------------------
ph_stub() { # ph_stub <name> [--exit N] [--out TEXT] [--sleep S] [--writes FILE:TEXT]
  local name="$1"; shift
  local code=0 out="" nap="" writes=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --exit)   code="$2"; shift 2 ;;
      --out)    out="$2";  shift 2 ;;
      --sleep)  nap="$2";  shift 2 ;;
      --writes) writes="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  {
    printf '#!/usr/bin/env bash\n'
    printf '{ printf "%%s" "%s"; for a in "$@"; do printf " [%%s]" "$a"; done; printf "\\n"; } >> "$PH_CALLS"\n' "$name"
    printf 'printf "+%s\\n" >> "$PH_SEQ"\n' "$name"
    [ -n "$nap" ]    && printf 'sleep %s\n' "$nap"
    printf 'printf -- "-%s\\n" >> "$PH_SEQ"\n' "$name"
    [ -n "$out" ]    && printf 'printf "%%s\\n" %q\n' "$out"
    [ -n "$writes" ] && printf 'printf "%%s\\n" %q > %q\n' "${writes#*:}" "${writes%%:*}"
    printf 'exit %s\n' "$code"
  } > "$PH_STUBS/$name"
  chmod +x "$PH_STUBS/$name"
}

ph_unstub() { rm -f "$PH_STUBS/$1"; }
ph_calls()  { cat "$PH_CALLS" 2>/dev/null; }

# Lines on stdin. BSD wc pads its number with spaces, so "$(wc -l)" compares
# unequal to 130 on macOS and equal on Linux; count without wc and the
# assertion means the same thing everywhere.
ph_nlines() { local n=0; while IFS= read -r _; do n=$((n+1)); done; printf '%s' "$n"; }
ph_called() { grep -q "^$1" "$PH_CALLS" 2>/dev/null; }
ph_ncalls() { local n; n="$(grep -c . "$PH_CALLS" 2>/dev/null)"; printf '%s' "${n:-0}"; }
ph_reset()  { : > "$PH_CALLS"; : > "$PH_SEQ"; }

# How many of these ran at the same time. Wall-clock proves parallelism only
# on a machine whose fork is cheap: Cygwin's is not, and a threshold that
# passes on Linux measures the runner, not the hook.
ph_concurrency() { # ph_concurrency <name> -> largest number running at once
  awk -v n="$1" '$0=="+" n {c++; if (c>m) m=c} $0=="-" n {c--} END {print m+0}' \
    "$PH_SEQ" 2>/dev/null || printf 0
}

# --- running the hook ----------------------------------------------------
# Sets RC (exit code), OUT (stdout), ERR (stderr), DUR (seconds) for the caller.
# shellcheck disable=SC2034  # these four are read by the test files, not here
ph_run() { # ph_run <hook-path> [json]
  local hook="$1" json="${2:-{\"stop_hook_active\":false\}}" t0=$SECONDS
  OUT="$(printf '%s' "$json" | bash "$hook" 2>"$PH_ROOT/err")"; RC=$?
  ERR="$(cat "$PH_ROOT/err")"; DUR=$((SECONDS - t0))
}

# --- result --------------------------------------------------------------
ph_summary() {
  printf '\n  %s ok, %s échec(s)' "$PH_PASS" "$PH_FAIL"
  [ "$PH_WARN" -gt 0 ] && printf ', %s avertissement(s)' "$PH_WARN"
  printf '\n'
  [ "$PH_FAIL" -eq 0 ]
}

# --- the contract -------------------------------------------------------
# Assertions any Claude Code hook should satisfy, whatever it does.
# Point it at someone else's hook and it tells you where that hook lies to you.
#
#   ph_contract path/to/hook.sh --event Stop --budget 5
#
# Hard failures are things that make a hook silently useless. Warnings are
# smells: legal, but dead weight.

# Run a command with a timeout, portably (no `timeout` on every Git Bash).
_ht_timed() { # _ht_timed <seconds> <file-for-rc> <command...>
  local limit="$1" rcfile="$2"; shift 2
  ( "$@"; printf '%s' "$?" > "$rcfile" ) &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    [ "$waited" -ge "$limit" ] && { kill -TERM "$pid" 2>/dev/null; sleep 1; kill -KILL "$pid" 2>/dev/null; printf 'TIMEOUT' > "$rcfile"; return 1; }
    sleep 1; waited=$((waited+1))
  done
  wait "$pid" 2>/dev/null
  return 0
}

_ht_shell_error() { # does this stderr carry a shell-level failure?
  printf '%s' "$1" | grep -qiE 'unbound variable|command not found|syntax error|: line [0-9]+:|No such file or directory'
}

ph_contract() { # ph_contract <hook> [--event NAME] [--budget SECONDS]
  local hook="$1"; shift
  local event=Stop budget=5
  while [ $# -gt 0 ]; do
    case "$1" in
      --event)  event="$2";  shift 2 ;;
      --budget) budget="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -f "$hook" ] || { _ht_ko "contrat : le hook existe" "introuvable : $hook"; return 1; }

  ph_case "contrat ($event)"

  case "$hook" in
    *.sh) ph_true "le script est syntaxiquement valide" "bash -n '$hook'" ;;
  esac

  local rcf="$PH_ROOT/contract.rc" before after

  # 1. A hook that has already blocked once must let the turn end.
  case "$event" in
    Stop|SubagentStop)
      ph_repo >/dev/null
      ph_run "$hook" '{"session_id":"x","stop_hook_active":true}'
      ph_eq "sort en 0 quand stop_hook_active est vrai" 0 "$RC"
      ph_false "n'émet pas d'erreur shell" "_ht_shell_error \"\$ERR\""
      ;;
  esac

  # 2. Nothing changed: a hook that blocks here blocks forever.
  ph_repo >/dev/null
  ph_run "$hook"
  ph_eq "sort en 0 sur un dépôt propre" 0 "$RC"
  ph_false "pas d'erreur shell sur un dépôt propre" "_ht_shell_error \"\$ERR\""

  # 3. Outside a repository, or with no stdin at all.
  local out="$PH_ROOT/nogit"; rm -rf "$out"; mkdir -p "$out"; ( cd "$out" && ph_run "$hook" )
  ph_false "ne plante pas hors d'un dépôt git" "_ht_shell_error \"\$ERR\""

  ph_repo >/dev/null
  : > "$rcf"
  _ht_timed "$budget" "$rcf" bash -c "printf '' | bash '$hook' >/dev/null 2>&1"
  ph_false "ne se bloque pas sur une entrée vide" "[ \"\$(cat '$rcf')\" = TIMEOUT ]"

  : > "$rcf"
  _ht_timed "$budget" "$rcf" bash -c "printf 'not json at all' | bash '$hook' >/dev/null 2>&1"
  ph_false "ne se bloque pas sur une entrée malformée" "[ \"\$(cat '$rcf')\" = TIMEOUT ]"

  # 4. Budget. A hook that overruns its timeout is cancelled and its verdict lost.
  ph_repo >/dev/null
  printf 'change\n' > contract-probe.txt
  before="$(ls -d "${TMPDIR:-/tmp}"/tmp.* 2>/dev/null | sort)"
  ph_run "$hook"
  after="$(ls -d "${TMPDIR:-/tmp}"/tmp.* 2>/dev/null | sort)"
  ph_true "tient dans son budget de ${budget}s (mesuré ${DUR}s)" "[ '$DUR' -le '$budget' ]"
  ph_eq "ne laisse pas de dossier temporaire" "$before" "$after"
  ph_true "code de sortie compris (0, 1 ou 2), obtenu $RC" "[ '$RC' = 0 ] || [ '$RC' = 1 ] || [ '$RC' = 2 ]"

  # 5. Smells rather than failures.
  if [ "$RC" = 0 ] && [ -n "$OUT" ]; then
    case "$OUT" in
      '{'*'}') : ;;
      *) _ht_warn "écrit sur stdout en sortant 0" "Claude ne lit pas stdout sur ce type d'événement : ce texte est perdu." ;;
    esac
  fi
  if [ "$RC" = 1 ]; then
    _ht_warn "sort en 1 pour signaler un problème" "1 est une erreur non bloquante ; pour bloquer, c'est 2 avec le motif sur stderr."
  fi
}
