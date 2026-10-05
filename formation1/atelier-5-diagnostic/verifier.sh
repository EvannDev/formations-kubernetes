#!/usr/bin/env bash
# Workshop 5 — checks that the four mandatory apps (and the bonus one) are
# healthy and stable, and that a diagnosis sheet is filled for each.
# Messages never reveal a cause: the workshop is a black-box diagnosis.
# Prints ✅/❌ per check; exit code ≠ 0 if at least one mandatory check fails.
# Messages are in French: participants read them.
set -uo pipefail

NS="bdc-diagnostic"
APPS=(virements-interac notifications-client moteur-scoring releves-partenaires)
BONUS_APP="portefeuille-titres"
# A pod must have run this long without failing: some faults only show up
# after a while (90 s and more).
MIN_STABLE_SECONDS=150
SHEET_SECTIONS=("Symptôme" "Commande" "Cause" "Correctif")
failures=0

ok()   { echo "✅ $*"; }
fail() { echo "❌ $*"; failures=$((failures + 1)); }
info() { echo "➖ $*"; }

cd "$(dirname "$0")"

# Prints "ok" or a short French reason why the app is not healthy yet.
app_health() {
  local app=$1 ready running_since
  ready=$(kubectl get deploy "$app" -n "$NS" \
    -o jsonpath='{.status.readyReplicas}/{.status.updatedReplicas}/{.status.replicas}' 2>/dev/null)
  [[ -n "$ready" ]] || { echo "Deployment introuvable"; return; }
  [[ "$ready" == "1/1/1" ]] || { echo "pas Ready (prêts/à jour/total : ${ready})"; return; }

  running_since=$(kubectl get pods -n "$NS" -l "app.kubernetes.io/name=${app}" \
    -o jsonpath='{.items[0].status.containerStatuses[0].state.running.startedAt}' 2>/dev/null)
  [[ -n "$running_since" ]] || { echo "conteneur pas en cours d'exécution"; return; }
  local age=$(( $(date +%s) - $(date -d "$running_since" +%s) ))
  if (( age < MIN_STABLE_SECONDS )); then
    echo "stable depuis ${age} s seulement : relancez dans $(( MIN_STABLE_SECONDS - age )) s pour confirmer"
    return
  fi
  echo "ok"
}

# Prints the empty sections of a sheet (comments and blank lines do not count).
empty_sections() {
  awk -v sections="$(IFS='|'; echo "${SHEET_SECTIONS[*]}")" '
    BEGIN { n = split(sections, list, "|"); for (i = 1; i <= n; i++) filled[list[i]] = 0 }
    /<!--/ { in_comment = 1 }
    in_comment { if (/-->/) in_comment = 0; next }
    /^## / { current = substr($0, 4); next }
    current != "" && NF > 0 { filled[current] = 1 }
    END { for (i = 1; i <= n; i++) if (!filled[list[i]]) printf "%s ", list[i] }
  ' "$1"
}

check_sheet() {
  local app=$1 sheet="fiches/${1}.md" missing
  if [[ ! -f "$sheet" ]]; then
    echo "fiche ${sheet} absente (cp fiches/GABARIT.md ${sheet})"
    return
  fi
  missing=$(empty_sections "$sheet")
  if [[ -n "$missing" ]]; then
    echo "fiche incomplète, rubrique(s) vide(s) : ${missing% }"
    return
  fi
  echo "ok"
}

echo "Atelier 5 — vérification dans le namespace « ${NS} »"
echo

if ! kubectl get namespace "$NS" >/dev/null 2>&1; then
  fail "Le namespace ${NS} n'existe pas (lancez ./deployer-pannes.sh)"
  exit 1
fi

for app in "${APPS[@]}"; do
  health=$(app_health "$app")
  if [[ "$health" == "ok" ]]; then
    ok "${app} : Ready et stable"
  else
    fail "${app} : ${health}"
  fi
  sheet=$(check_sheet "$app")
  if [[ "$sheet" == "ok" ]]; then
    ok "${app} : fiche remplie"
  else
    fail "${app} : ${sheet}"
  fi
done

echo
health=$(app_health "$BONUS_APP")
sheet=$(check_sheet "$BONUS_APP")
if [[ "$health" == "ok" && "$sheet" == "ok" ]]; then
  ok "Bonus ${BONUS_APP} : Ready, stable, fiche remplie ⭐"
else
  [[ "$health" == "ok" ]] || info "Bonus ${BONUS_APP} : ${health}"
  [[ "$sheet" == "ok" ]] || info "Bonus ${BONUS_APP} : ${sheet}"
fi

echo
if (( failures == 0 )); then
  echo "🎉 Atelier 5 réussi."
else
  echo "${failures} critère(s) en échec."
fi
exit $(( failures > 0 ? 1 : 0 ))
