#!/usr/bin/env bash
# stop-gate — run your project's checks before Claude hands the turn back.
#
# A Stop hook fires at the end of every turn. That makes it the right place to
# replay the gates your CI would fail on — and the wrong place to re-run a test
# suite on a tree that has not changed since the last verdict.
#
# This hook:
#   - remembers the state it last ruled on, and does nothing until the tree moves
#   - applies the mechanical fixes itself (formatters) instead of nagging
#   - runs the slow checks in parallel and waits for the slowest, not their sum
#   - blocks once per state with exit 2, stderr carrying the reason
#   - records what it ran, and how long, in .git/stop-gate.log
#
# Configuration: .claude/stop-gate.conf, one rule per line.
#
#     # mode   glob                       command
#     fix      resources/**               npx prettier --write
#     check    **/*.ts                    npm run types
#     check    **/*.php                   vendor/bin/pint --test --dirty
#
#   fix    runs when a matching file changed; the changed paths are appended to
#          the command. It only blocks if the command itself fails.
#   check  runs when a matching file changed; a non-zero exit blocks the turn.
#
# Force a re-run: delete .git/stop-gate.sig
#
# Verified against Claude Code 2.1.323.

set -u

CONF="${STOP_GATE_CONF:-.claude/stop-gate.conf}"

input="$(cat)"
# Already blocked once this turn: let it through rather than loop.
case "$input" in *'"stop_hook_active"'*'true'*) exit 0 ;; esac

root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
cd "$root" || exit 0
export GIT_OPTIONAL_LOCKS=0   # a background hook must not hold the index lock

gitdir="$(git rev-parse --git-dir 2>/dev/null)" || gitdir=""
stamp="${gitdir:+$gitdir/stop-gate.sig}"
log="${gitdir:+$gitdir/stop-gate.log}"
[ -f "$CONF" ] || exit 0

# --- what changed --------------------------------------------------------
# -z keeps paths raw (spaces, accents); -uall lists files inside new folders.
entries=""; changed=""
scan() {
  entries="$(git status --porcelain=v1 -uall -z 2>/dev/null | while IFS= read -r -d '' e; do
    printf '%s\t%s\n' "${e:0:2}" "${e:3}"
    # The leading ( is not decoration: bash 3.2, still /bin/bash on macOS,
    # counts parentheses naively inside $( ) and takes the one closing a case
    # pattern as the end of the substitution.
    case "${e:0:2}" in (R?|C?|?R|?C) IFS= read -r -d '' from && printf '<-\t%s\n' "$from" ;; esac
  done)"
  changed="$(printf '%s\n' "$entries" | cut -f2- | sort -u | grep -v '^$')"
}

# Fingerprint of this exact state: HEAD, the status lines, and file contents.
state_sig() {
  {
    git rev-parse HEAD 2>/dev/null
    printf '%s\n' "$entries"
    printf '%s\n' "$changed" | while IFS= read -r f; do
      [ -n "$f" ] && [ -f "$f" ] && printf '%s\n' "$f"
    done | git hash-object --stdin-paths 2>/dev/null
  } | git hash-object --stdin 2>/dev/null
}

scan
[ -z "$changed" ] && exit 0
sig="$(state_sig)"
# An empty fingerprint means git failed: never treat that as "already seen".
if [ -n "$sig" ] && [ -n "$stamp" ] && [ -f "$stamp" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$sig" ]; then
  exit 0
fi

# --- glob matching -------------------------------------------------------
# `**` spans directories, `*` does not. Pure bash, no shell globbing involved.
matches() { # matches <glob> <path>
  local glob="$1" path="$2" re=""
  while [ -n "$glob" ]; do
    case "$glob" in
      '**/'*) re+='(.*/)?'; glob="${glob#'**/'}" ;;
      '**'*)  re+='.*';     glob="${glob#'**'}"  ;;
      '*'*)   re+='[^/]*';  glob="${glob#'*'}"   ;;
      '?'*)   re+='[^/]';   glob="${glob#'?'}"   ;;
      *)      re+="$(printf '%s' "${glob:0:1}" | sed 's/[.[\()*+?^$|]/\\&/g')"; glob="${glob:1}" ;;
    esac
  done
  printf '%s' "$path" | grep -qE "^${re}$"
}

matched_files() { # matched_files <glob> -> changed files matching, that still exist
  printf '%s\n' "$changed" | while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] && matches "$1" "$f" && printf '%s\n' "$f"
  done
}

# --- run -----------------------------------------------------------------
tmp="$(mktemp -d)"; trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$tmp"' EXIT
problems=""; did=""; timings=""; n=0

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|'#'*) continue ;; esac
  mode="$(printf '%s' "$line" | awk '{print $1}')"
  glob="$(printf '%s' "$line" | awk '{print $2}')"
  cmd="$(printf '%s' "$line" | awk '{ $1=""; $2=""; sub(/^[ \t]+/,""); print }')"
  [ -z "$mode" ] || [ -z "$glob" ] || [ -z "$cmd" ] && continue

  files="$(matched_files "$glob")"
  [ -z "$files" ] && continue

  case "$mode" in
    fix)
      # Formatters are mechanical: apply them rather than report them.
      out="$(printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 -n 60 $cmd 2>&1)" \
        && did+=" $(printf '%s' "$cmd" | awk '{print $1}')" \
        || problems+=$'\n'"- \`$cmd\` a échoué :"$'\n'"$(printf '%s\n' "$out" | tail -n 12)"
      ;;
    check)
      n=$((n+1))
      ( t0=$SECONDS; eval "$cmd" >"$tmp/$n.out" 2>&1
        printf '%s %s\n' "$?" "$((SECONDS-t0))" >"$tmp/$n.rc" ) &
      printf '%s\n' "$cmd" >"$tmp/$n.cmd"
      ;;
  esac
done < "$CONF"

wait
i=0
while [ "$i" -lt "$n" ]; do
  i=$((i+1))
  rc="$(cut -d' ' -f1 "$tmp/$i.rc" 2>/dev/null || echo 1)"
  secs="$(cut -d' ' -f2 "$tmp/$i.rc" 2>/dev/null || echo '?')"
  cmd="$(cat "$tmp/$i.cmd")"
  timings+=" $(printf '%s' "$cmd" | awk '{print $NF}')=${secs}s"
  [ "$rc" = "0" ] || problems+=$'\n'"- \`$cmd\` échoue :"$'\n'"$(tail -n 12 "$tmp/$i.out" 2>/dev/null)"
done

# --- record and rule -----------------------------------------------------
if [ -n "$log" ] && [ -n "$problems$did$timings" ]; then
  verdict=OK; [ -n "$problems" ] && verdict=KO
  { tail -n 199 "$log" 2>/dev/null
    printf '%s %s %ss%s%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$verdict" "$SECONDS" "$timings" "${did:+ | appliqué :$did}"
  } >"$log.tmp" 2>/dev/null && mv -f "$log.tmp" "$log" 2>/dev/null
fi

# Remember the state this verdict covers, fixes included. A red state is
# reported once: repeating it every turn teaches nothing, and CI is the net.
scan
[ -n "$stamp" ] && state_sig >"$stamp" 2>/dev/null

if [ -n "$problems" ]; then
  printf 'Des contrôles échouent en local, à corriger avant de rendre la main :%s\n' "$problems" >&2
  [ -n "$did" ] && printf '\nDéjà appliqué par le hook (relire un fichier avant de le modifier) :%s\n' "$did" >&2
  exit 2
fi
exit 0
