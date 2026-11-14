#!/usr/bin/env bash
# Tests for the harness itself, and for the contract.
# Run: bash lib/test.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./harness.sh
source "$HERE/harness.sh"
FIX="$HERE/fixtures"

# Run a contract in a subshell and hand back its report, so a deliberate
# failure in a fixture does not fail this suite.
report() { ( ph_contract "$@" ) 2>&1; }

echo "harness + contrat"

ph_case "les commandes simulées enregistrent leurs arguments"
ph_repo; ph_stub npm --exit 3 --out "boom"
out="$(npm run types --flag 2>&1)"; rc=$?
ph_eq "le code de sortie est respecté" 3 "$rc"
ph_eq "la sortie est respectée" "boom" "$out"
ph_true "l'appel est enregistré avec ses arguments" "ph_calls | grep -q '^npm \[run\] \[types\] \[--flag\]$'"
ph_eq "ph_ncalls compte juste" 1 "$(ph_ncalls)"
ph_reset; ph_eq "ph_reset remet à zéro" 0 "$(ph_ncalls)"

ph_case "ph_run expose code, sortie, erreur et durée"
ph_repo; ph_run "$FIX/good.sh"
ph_eq "RC" 0 "$RC"; ph_eq "OUT" "" "$OUT"; ph_eq "ERR" "" "$ERR"
ph_true "DUR est un nombre" "[ '$DUR' -ge 0 ]"

ph_case "chaque ph_repo est un dépôt neuf et isolé"
ph_repo; echo 'un' > marker.txt; first="$PWD"
ph_repo; ph_false "le fichier précédent n'est pas là" "[ -f marker.txt ]"
ph_true "c'est bien un autre dossier" "[ '$PWD' != '$first' ]"
ph_true "et un dépôt git valide" "git rev-parse --git-dir >/dev/null 2>&1"

ph_case "le contrat valide un hook correct"
r="$(report "$FIX/good.sh" --event Stop)"
ph_lacks "aucun échec" "$r" "FAIL"
ph_lacks "aucun avertissement" "$r" "warn"

ph_case "le contrat attrape un hook qui boucle"
r="$(report "$FIX/loops.sh" --event Stop)"
ph_contains "signale qu'il ignore stop_hook_active" "$r" "FAIL sort en 0 quand stop_hook_active est vrai"
ph_contains "signale qu'il bloque un dépôt propre" "$r" "FAIL sort en 0 sur un dépôt propre"

ph_case "le contrat attrape un hook qui se bloque"
r="$(report "$FIX/hangs.sh" --event Stop --budget 3)"
ph_contains "signale le dépassement de budget" "$r" "FAIL tient dans son budget"

ph_case "le contrat attrape une erreur shell"
r="$(report "$FIX/unbound.sh" --event Stop)"
ph_contains "signale l'erreur shell" "$r" "FAIL n'émet pas d'erreur shell"

ph_case "le contrat attrape un dossier temporaire abandonné"
r="$(report "$FIX/litters.sh" --event Stop)"
ph_contains "signale le résidu" "$r" "FAIL ne laisse pas de dossier temporaire"

ph_case "le contrat distingue un défaut d'un simple travers"
r="$(report "$FIX/chatty.sh" --event Stop)"
ph_lacks "pas d'échec" "$r" "FAIL"
ph_contains "mais un avertissement sur stdout" "$r" "warn écrit sur stdout"

ph_summary
