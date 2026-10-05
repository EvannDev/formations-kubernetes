#!/usr/bin/env bash
# Workshop 3 — checks the three probes of api-paiements in $NS.
# Prints ✅/❌ per check; exit code ≠ 0 if at least one check fails.
# Messages are in French: participants read them.
set -uo pipefail

NS="${NS:-bdc}"
APP="api-paiements"
SELECTOR="app.kubernetes.io/name=${APP}"
EXPECTED_REPLICAS=3
EXPECTED_STARTUP_DELAY=45
MIN_STARTUP_BUDGET=60
failures=0

ok()   { echo "✅ $*"; }
fail() { echo "❌ $*"; failures=$((failures + 1)); }

# Reads a field of the app container in the Deployment template
container_field() {
  kubectl get deploy "$APP" -n "$NS" -o jsonpath="{.spec.template.spec.containers[0].$1}" 2>/dev/null
}

echo "Atelier 3 — vérification dans le namespace « ${NS} »"
echo

if ! kubectl get deploy "$APP" -n "$NS" >/dev/null 2>&1; then
  fail "Deployment ${APP} introuvable dans ${NS} (avez-vous fait « export NS=bdc » ?)"
  exit 1
fi

# 1. Rollout finished: 3 replicas ready and up to date
ready=$(kubectl get deploy "$APP" -n "$NS" -o jsonpath='{.status.readyReplicas}')
updated=$(kubectl get deploy "$APP" -n "$NS" -o jsonpath='{.status.updatedReplicas}')
total=$(kubectl get deploy "$APP" -n "$NS" -o jsonpath='{.status.replicas}')
if [[ "${ready:-0}" == "$EXPECTED_REPLICAS" && "${updated:-0}" == "$EXPECTED_REPLICAS" && "${total:-0}" == "$EXPECTED_REPLICAS" ]]; then
  ok "Deployment ${APP} : ${EXPECTED_REPLICAS}/${EXPECTED_REPLICAS} pods Ready, rollout terminé"
else
  fail "Deployment ${APP} : prêts=${ready:-0}, à jour=${updated:-0}, total=${total:-0} (attendu : ${EXPECTED_REPLICAS} partout ; rollout en cours ?)"
fi

# 2. No restart on the active pods
restarts=$(kubectl get pods -n "$NS" -l "$SELECTOR" \
  -o jsonpath='{range .items[*]}{.metadata.deletionTimestamp}{"|"}{.status.containerStatuses[0].restartCount}{"\n"}{end}' 2>/dev/null \
  | awk -F'|' '$1 == "" {s += $2} END {print s + 0}')
if [[ "$restarts" == "0" ]]; then
  ok "Pods ${APP} : 0 restart"
else
  fail "Pods ${APP} : ${restarts} restart(s) (attendu : 0 ; voir kubectl describe pod)"
fi

# 3. The slow startup is still there (it is the app's reality, not a defect)
startup_delay=$(container_field 'env[?(@.name=="DELAI_DEMARRAGE")].value')
if [[ "$startup_delay" == "$EXPECTED_STARTUP_DELAY" ]]; then
  ok "Démarrage lent conservé (DELAI_DEMARRAGE=${EXPECTED_STARTUP_DELAY})"
else
  fail "DELAI_DEMARRAGE vaut « ${startup_delay:-absente} » (attendu : ${EXPECTED_STARTUP_DELAY}) : l'appli démarre lentement, les sondes doivent s'y adapter"
fi

# 4. startupProbe present, with a budget covering the slow startup.
#    Budget = initialDelaySeconds + periodSeconds × failureThreshold (API defaults: 0, 10, 3)
if [[ -n "$(container_field 'startupProbe')" ]]; then
  initial=$(container_field 'startupProbe.initialDelaySeconds')
  period=$(container_field 'startupProbe.periodSeconds')
  threshold=$(container_field 'startupProbe.failureThreshold')
  budget=$(( ${initial:-0} + ${period:-10} * ${threshold:-3} ))
  if (( budget >= MIN_STARTUP_BUDGET )); then
    ok "startupProbe présente, budget ${budget} s (minimum : ${MIN_STARTUP_BUDGET} s)"
  else
    fail "startupProbe présente, mais budget de ${budget} s seulement (minimum : ${MIN_STARTUP_BUDGET} s pour 45 s de démarrage)"
  fi
else
  fail "Pas de startupProbe"
fi

# 5. Liveness and readiness on the right routes
liveness_path=$(container_field 'livenessProbe.httpGet.path')
if [[ "$liveness_path" == "/healthz" ]]; then
  ok "Liveness sur /healthz"
else
  fail "Liveness sur « ${liveness_path:-aucune} » (attendu : /healthz)"
fi
readiness_path=$(container_field 'readinessProbe.httpGet.path')
if [[ "$readiness_path" == "/readyz" ]]; then
  ok "Readiness sur /readyz"
else
  fail "Readiness sur « ${readiness_path:-aucune} » (attendu : /readyz)"
fi

# 6. No experiment leftovers: they would make the pods fail a few minutes later
leftovers=""
for variable in READINESS_ECHOUE_APRES LIVENESS_ECHOUE_APRES; do
  [[ -n "$(container_field "env[?(@.name==\"${variable}\")].value")" ]] && leftovers+="${variable} "
done
if [[ -z "$leftovers" ]]; then
  ok "Aucune variable d'expérience restante"
else
  fail "Variable(s) d'expérience encore présente(s) : ${leftovers% } (à retirer du fichier, puis kubectl apply)"
fi

# 7. Service: 3 ready endpoints
ready_endpoints=$(kubectl get endpointslices -n "$NS" -l "kubernetes.io/service-name=${APP}" \
  -o jsonpath='{range .items[*].endpoints[*]}{.conditions.ready}{"\n"}{end}' 2>/dev/null \
  | grep -c '^true$' || true)
if [[ "$ready_endpoints" == "$EXPECTED_REPLICAS" ]]; then
  ok "Service ${APP} : ${ready_endpoints} endpoints prêts"
else
  fail "Service ${APP} : ${ready_endpoints} endpoint(s) prêt(s) (attendu : ${EXPECTED_REPLICAS})"
fi

echo
if (( failures == 0 )); then
  echo "🎉 Atelier 3 réussi."
else
  echo "${failures} critère(s) en échec."
fi
exit $(( failures > 0 ? 1 : 0 ))
