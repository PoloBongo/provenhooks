#!/usr/bin/env bash
# Suite for secret-guard. Run: bash hooks/secret-guard/test.sh
#
# No credential appears whole in this file. Every one is assembled at run
# time from pieces, so the suite does not trip the hook it tests, does not
# arm a repository scanner, and does not put a copy-pasteable shape in front
# of anyone reading the tests.
set -u
cd "$(dirname "$0")/../.." || exit 1
. lib/harness.sh
HOOK="$PWD/hooks/secret-guard/secret-guard.sh"

# payload <tool> <content>
payload() { printf '{"tool_name":"%s","tool_input":{"file_path":"x","content":"%s"}}' "$1" "$2"; }
write()   { ph_run "$HOOK" "$(payload Write "$1")"; }

echo "secret-guard"

ph_contract "$HOOK" --event PreToolUse

# --- ce qui doit bloquer -------------------------------------------------
ph_case "les identifiants réels sont bloqués"
blocks() { # blocks <nom> <secret>
  write "$2"
  ph_eq "$1 : code 2" 2 "$RC"
  ph_true "$1 : la raison est sur stderr" "[ -n \"\$ERR\" ]"
}
blocks "clé AWS"        "AKIA""Q3RJ7LKM2WVBZT4C"
blocks "token GitHub"   "ghp""_9fK2mQ7xZt4bV1nR8cL3yW6dA0sJ5hG2pE7u"
blocks "token Slack"    "xoxb""-2f7Kq9Lm4Rt8Wv1Nz6Hc3Jd5"
blocks "clé Stripe"     "sk_live""_4RtYu7Ki9Lm2Nb5Vc8Xz3Qw6"
blocks "clé Google"     "AIza""SyD9fK2mQ7xZt4bV1nR8cL3yW6dA0sJ5hG2"
blocks "clé OpenAI"     "sk-""proj-9fK2mQ7xZt4bV1nR8cL3yW6dA0sJ5hG2pE7u"
blocks "clé Anthropic"  "sk-ant""-api03-9fK2mQ7xZt4bV1nR8cL3yW6"
blocks "clé privée"     "-----BEGIN RSA PRIVATE KEY-----"
blocks "clé OpenSSH"    "-----BEGIN OPENSSH PRIVATE KEY-----"
blocks "JWT"            "eyJhbGciOiJIUzI1NiJ9"".""eyJzdWIiOiIxMjM0NTYifQ"".""dBjftJeZ4CVPmB92K27u"

# --- ce qui ne doit pas bloquer -----------------------------------------
ph_case "les exemples et la prose passent"
passes() { # passes <nom> <contenu>
  write "$2"
  ph_eq "$1" 0 "$RC"
}
passes "placeholder en x"        "AWS_KEY=AKIA""XXXXXXXXXXXXXXXX"
passes "placeholder nommé"       "token: ghp""_YOUR_TOKEN_HERE_0000000000000000000000"
passes "variable d'environnement" "key: \${AWS_ACCESS_KEY_ID}"
passes "chevrons"                "Authorization: Bearer <votre-token>"
passes "valeur vide"             "STRIPE_KEY="
passes "prose"                   "Le mot de passe vit dans un coffre, jamais dans le code."
passes "constante homonyme"      "const BEGIN_PRIVATE_KEY_HEADER = 42;"
passes "base64 quelconque"       "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB"
passes "sk- trop court"          "sk-abc123"

ph_case "seuls les outils d'écriture sont concernés"
secret="AKIA""Q3RJ7LKM2WVBZT4C"
for tool in Write Edit MultiEdit NotebookEdit; do
  ph_run "$HOOK" "$(payload "$tool" "$secret")"
  ph_eq "$tool : bloqué" 2 "$RC"
done
for tool in Read Bash Grep Glob WebFetch; do
  ph_run "$HOOK" "$(payload "$tool" "$secret")"
  ph_eq "$tool : laissé passer" 0 "$RC"
done

ph_case "le hook ne recopie pas le secret qu'il bloque"
write "$secret"
ph_lacks "stderr ne contient pas la clé entière" "$ERR" "$secret"
ph_contains "stderr nomme le type trouvé" "$ERR" "AWS"
ph_eq "stdout vide" "" "$OUT"

ph_case "échappatoire explicite"
write "key = \\\"$secret\\\" // secret-guard: allow"
ph_eq "la ligne marquée passe" 0 "$RC"
write "$secret"
ph_eq "la ligne suivante bloque toujours" 2 "$RC"

ph_case "plusieurs secrets dans la même écriture"
write "a=AKIA""Q3RJ7LKM2WVBZT4C et b=ghp""_9fK2mQ7xZt4bV1nR8cL3yW6dA0sJ5hG2pE7u"
ph_eq "code 2" 2 "$RC"
ph_contains "les deux sont nommés : AWS" "$ERR" "AWS"
ph_contains "les deux sont nommés : GitHub" "$ERR" "GitHub"

ph_summary
