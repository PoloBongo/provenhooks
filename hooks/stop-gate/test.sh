#!/usr/bin/env bash
# Tests for stop-gate. Run: bash hooks/stop-gate/test.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/harness.sh
source "$HERE/../../lib/harness.sh"
HOOK="$HERE/stop-gate.sh"

conf() { mkdir -p .claude; printf '%s\n' "$@" > .claude/stop-gate.conf; }

echo "stop-gate"

ph_contract "$HOOK" --event Stop

ph_case "sans configuration, le hook ne fait rien"
ph_repo; ph_stub npm; echo 'x' > a.ts; ph_run "$HOOK"
ph_eq "code 0" 0 "$RC"
ph_eq "aucune commande" 0 "$(ph_ncalls)"

ph_case "arbre propre, rien à faire"
ph_repo; conf 'check **/*.ts npm run types'; git add -A; git commit -qm c; ph_reset; ph_run "$HOOK"
ph_eq "code 0" 0 "$RC"
ph_eq "aucune commande" 0 "$(ph_ncalls)"

ph_case "une règle check qui passe"
ph_repo; conf 'check **/*.ts npm run types'; ph_stub npm; echo 'export const a=1' > a.ts; ph_run "$HOOK"
ph_eq "code 0" 0 "$RC"
ph_true "npm appelé" "ph_called npm"
ph_eq "stdout vide" "" "$OUT"
ph_true "empreinte mémorisée" "[ -s .git/stop-gate.sig ]"
ph_true "journal écrit" "grep -q ' OK ' .git/stop-gate.log"

ph_case "même état : rien n'est rejoué"
ph_reset; ph_run "$HOOK"
ph_eq "code 0" 0 "$RC"
ph_eq "aucune commande" 0 "$(ph_ncalls)"

ph_case "le fichier change : on rejoue"
ph_reset; echo 'export const a=2' > a.ts; ph_run "$HOOK"
ph_true "npm rappelé" "ph_called npm"

ph_case "une règle check qui échoue bloque une fois"
ph_repo; conf 'check **/*.ts npm run types'
ph_stub npm --exit 1 --out "a.ts(3,7): error TS2322: Type 'x' is not	assignable"
echo 'export const a=1' > a.ts; ph_run "$HOOK"
ph_eq "code 2" 2 "$RC"
ph_eq "stdout vide" "" "$OUT"
ph_contains "stderr cite la commande" "$ERR" 'npm run types'
ph_contains "stderr garde la sortie brute, tabulation comprise" "$ERR" "is not	assignable"
ph_true "journal KO" "grep -q ' KO ' .git/stop-gate.log"
n="$(ph_ncalls)"; ph_run "$HOOK"
ph_eq "même état rouge : ni rejoué ni rebloqué" 0 "$RC"
ph_eq "aucune commande de plus" "$n" "$(ph_ncalls)"
rm -f .git/stop-gate.sig; ph_run "$HOOK"
ph_eq "empreinte supprimée : rejeu forcé" 2 "$RC"

ph_case "stop_hook_active : laisse passer sans rien lancer"
ph_repo; conf 'check **/*.ts npm run types'; ph_stub npm; echo 'x' > a.ts
ph_run "$HOOK" '{"stop_hook_active":true}'
ph_eq "code 0" 0 "$RC"
ph_eq "aucune commande" 0 "$(ph_ncalls)"

ph_case "une règle fix applique au lieu de bloquer"
ph_repo; conf 'fix **/*.css npx prettier --write'
ph_stub npx; echo 'body{}' > a.css; ph_run "$HOOK"
ph_eq "code 0" 0 "$RC"
ph_true "le fichier est passé à la commande" "ph_calls | grep -q '\[--write\] \[a.css\]'"
ph_true "journal : appliqué" "grep -q 'appliqué : npx' .git/stop-gate.log"

ph_case "une règle fix qui échoue bloque, avec le détail"
ph_repo; conf 'fix **/*.css npx prettier --write'
ph_stub npx --exit 2 --out "SyntaxError: Unexpected token (3:1)"
echo 'body{' > a.css; ph_run "$HOOK"
ph_eq "code 2" 2 "$RC"
ph_contains "stderr : le détail" "$ERR" "SyntaxError"

ph_case "les globs : ** traverse, * non"
ph_repo; conf 'check **/*.ts npm deep' 'check *.ts npm shallow'
ph_stub npm; mkdir -p src/lib; echo 'x' > src/lib/deep.ts; ph_run "$HOOK"
ph_true "** attrape le fichier imbriqué" "ph_calls | grep -q 'npm \[deep\]'"
ph_false "* ne l'attrape pas" "ph_calls | grep -q 'npm \[shallow\]'"
ph_reset; echo 'y' > top.ts; ph_run "$HOOK"
ph_true "* attrape le fichier racine" "ph_calls | grep -q 'npm \[shallow\]'"

ph_case "une règle sans fichier concerné ne tourne pas"
ph_repo; conf 'check **/*.php npm php' 'check **/*.ts npm ts'
ph_stub npm; echo 'x' > a.ts; ph_run "$HOOK"
ph_true "la règle ts tourne" "ph_calls | grep -q 'npm \[ts\]'"
ph_false "la règle php ne tourne pas" "ph_calls | grep -q 'npm \[php\]'"

ph_case "noms de fichiers piégeux : espace, accent, renommage, suppression"
ph_repo; conf 'fix **/*.css npx fmt'; ph_stub npx
echo 'old{}' > old.css; echo 'gone{}' > gone.css; git add -A; git commit -qm c
mkdir -p "dir avec espace"; echo 'body{}' > "dir avec espace/é fichier.css"
git mv old.css new.css; rm -f gone.css; ph_reset; ph_run "$HOOK"
ph_eq "pas d'erreur bash" 0 "$RC"
ph_lacks "stderr sans erreur shell" "$ERR" "unbound"
ph_true "chemin avec espace et accent passé entier" "ph_calls | grep -qF '[dir avec espace/é fichier.css]'"
ph_true "renommage : le nouveau chemin est traité" "ph_calls | grep -qF '[new.css]'"
ph_false "l'ancien chemin est ignoré" "ph_calls | grep -qF '[old.css]'"
ph_false "le fichier supprimé est ignoré" "ph_calls | grep -qF '[gone.css]'"

ph_case "les checks tournent en parallèle"
ph_repo; conf 'check **/*.ts npm one' 'check **/*.ts npm two' 'check **/*.ts npm three'
ph_stub npm --sleep 2; echo 'x' > a.ts; ph_run "$HOOK"
ph_eq "code 0" 0 "$RC"
ph_eq   "les 3 tournent en même temps" 3 "$(ph_concurrency npm)"
ph_true "journal : une durée par check" "grep -qE 'one=[0-9]+s two=[0-9]+s three=[0-9]+s' .git/stop-gate.log"

ph_case "beaucoup de fichiers : la commande fix est appelée par paquets"
ph_repo; conf 'fix **/*.css npx fmt'; ph_stub npx
for i in $(seq 1 130); do echo "a{}" > "f$i.css"; done; ph_run "$HOOK"
ph_eq "3 appels (60+60+10)" 3 "$(ph_calls | grep -c '^npx')"
ph_eq "130 fichiers au total" 130 "$(ph_calls | grep -o '\[f[0-9]*\.css\]' | sort -u | ph_nlines)"

ph_case "commentaires et lignes vides ignorés"
ph_repo; conf '# un commentaire' '' 'check **/*.ts npm ts'; ph_stub npm; echo 'x' > a.ts; ph_run "$HOOK"
ph_eq "code 0" 0 "$RC"
ph_eq "une seule commande" 1 "$(ph_ncalls)"

ph_case "journal borné à 200 lignes"
ph_repo; conf 'check **/*.ts npm ts'; ph_stub npm
for i in $(seq 1 250); do echo "ligne $i"; done > .git/stop-gate.log
echo 'x' > a.ts; ph_run "$HOOK"
ph_eq "200 lignes" 200 "$(ph_nlines < .git/stop-gate.log)"

ph_case "empreinte incalculable : jamais de faux « déjà vu »"
ph_repo; conf 'check **/*.ts npm ts'; ph_stub npm; echo 'x' > a.ts
real_git="$(command -v git)"
printf '#!/usr/bin/env bash\n[ "${1:-}" = "hash-object" ] && exit 1\nexec %q "$@"\n' "$real_git" > "$PH_STUBS/git"
chmod +x "$PH_STUBS/git"
ph_run "$HOOK"; ph_true "1er passage : lancé" "ph_called npm"
ph_true "empreinte vide" "[ ! -s .git/stop-gate.sig ]"
ph_reset; ph_run "$HOOK"; ph_true "2e passage : rejoué" "ph_called npm"
ph_unstub git
ph_reset; ph_run "$HOOK"; ph_reset; ph_run "$HOOK"
ph_eq "git rétabli : l'état est mémorisé puis sauté" 0 "$(ph_ncalls)"

ph_summary
