#!/usr/bin/env bash
# secret-guard — refuse to write a credential into a file.
#
# A PreToolUse hook fires before Claude Code writes or edits a file. That is
# the last moment where a leaked key costs nothing: once it is on disk it
# tends to reach a commit, and once it is in a commit it has to be rotated,
# not deleted.
#
# This hook reads the tool call, looks for credentials that are
# unmistakably real, and blocks the write with exit 2 so Claude is told why
# and can fix it. Everything else passes untouched.
#
# What it deliberately does NOT do: guess. A scanner that blocks every long
# base64 string is a scanner people switch off within a week, and a switched
# off scanner protects nothing. So it matches issuer-specific shapes only
# (AWS, GitHub, Slack, Stripe, Google, OpenAI, Anthropic, private keys), and
# it stays quiet on placeholders: YOUR_KEY_HERE, sk-xxxx, ${VAR}, empty
# values in a .env.example.
#
# Why it scans the raw JSON rather than parsing it: the payload is the only
# input, jq is not everywhere, and a credential survives JSON encoding
# unchanged — none of these shapes contains a character JSON escapes. Reading
# the text directly is fewer moving parts than a hand-rolled JSON parser, and
# a key hidden in any field is still a key.
#
# Configuration: none. Allow one line with a trailing  secret-guard: allow
#
# Verified against Claude Code 2.1.323.

set -u

input="$(cat)"

# Only writes matter. A read, a search or a bash call is none of our business.
case "$input" in
  *'"tool_name"'*'"Write"'*|*'"tool_name"'*'"Edit"'*|\
  *'"tool_name"'*'"MultiEdit"'*|*'"tool_name"'*'"NotebookEdit"'*) ;;
  *) exit 0 ;;
esac

# name|regex — anchored on what the issuer actually emits, never on entropy.
PATTERNS='
AWS access key|AKIA[0-9A-Z]{16}
GitHub token|gh[pousr]_[A-Za-z0-9]{36,}
Slack token|xox[baprse]-[0-9A-Za-z-]{10,}
Stripe secret key|sk_live_[0-9a-zA-Z]{20,}
Google API key|AIza[0-9A-Za-z_-]{35}
OpenAI key|sk-(proj-)?[A-Za-z0-9_-]{32,}
Anthropic key|sk-ant-[A-Za-z0-9_-]{24,}
Private key block|-----BEGIN [A-Z ]*PRIVATE KEY-----
JSON Web Token|eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}
'

# A placeholder is not a secret. Documentation and .env.example are full of
# them, and blocking those is how a scanner loses the user's trust.
is_placeholder() { # is_placeholder <matched text>
  case "$1" in
    *xxxx*|*XXXX*|*ABCDEF*|*abcdef0123*|*0000*|*1234567890*|\
    *your*|*YOUR*|*Your*|*example*|*EXAMPLE*|*Example*|\
    *placeholder*|*PLACEHOLDER*|*changeme*|*CHANGEME*|\
    *dummy*|*DUMMY*|*sample*|*SAMPLE*|*redacted*|*REDACTED*|\
    *'${'*|*'<'*|*'%s'*) return 0 ;;
  esac
  return 1
}

found=""
while IFS='|' read -r name re; do
  [ -z "$name" ] && continue
  # -e is not optional: a pattern that starts with - (a PEM header) is read
  # as a bunch of options without it, and the match silently never happens.
  hits="$(printf '%s' "$input" | grep -oE -e "$re" 2>/dev/null | sort -u)"
  [ -z "$hits" ] && continue
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    is_placeholder "$hit" && continue
    # An explicit opt-out, on the same line as the match, in the payload.
    case "$input" in *"$hit"*'secret-guard: allow'*) continue ;; esac
    # Show the shape, never the whole credential: a blocked secret must not
    # be copied into the transcript by the thing that blocked it.
    masked="$(printf '%s' "$hit" | cut -c1-8)…$(printf '%s' "$hit" | tail -c 3)"
    found="$found
  - $name ($masked)"
  done <<EOF
$hits
EOF
done <<EOF
$PATTERNS
EOF

[ -z "$found" ] && exit 0

printf 'Cette écriture contient un identifiant qui semble réel :%s\n\n' "$found" >&2
printf 'Ne pas écrire un secret en dur. Au choix :\n' >&2
printf '  - le lire depuis une variable d'\''environnement ;\n' >&2
printf '  - le mettre dans un fichier ignoré par git, et ne versionner qu'\''un .example ;\n' >&2
printf '  - si c'\''est un exemple, le rendre visiblement factice (YOUR_KEY_HERE, sk-xxxx).\n' >&2
printf '\nSi ce cas précis est volontaire, ajouter  secret-guard: allow  en fin de ligne.\n' >&2
exit 2
