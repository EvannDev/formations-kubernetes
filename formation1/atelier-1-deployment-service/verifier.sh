#!/usr/bin/env bash
# Workshop 1 — checks the final state of api-paiements in $NS.
# Prints ✅/❌ per check; exit code ≠ 0 if at least one check fails.
# Messages are in French: participants read them.
set -uo pipefail

NS="${NS:-bdc}"
APP="api-paiements"
SELECTOR="app.kubernetes.io/name=${APP}"
EXPECTED_VERSION="1.0"
EXPECTED_REPLICAS=3
failures=0

ok()   { echo "✅ $*"; }
fail() { echo "❌ $*"; failures=$((failures + 1)); }

echo "Atelier 1 — vérification dans le namespace « ${NS} »"
echo

if ! kubectl get namespace "$NS" >/dev/null 2>&1; then
  fail "Le namespace ${NS} n'existe pas (avez-vous fait « export NS=bdc » ?)"
  exit 1
fi

# 1. Deployment: 3 replicas ready and up to date
if kubectl get deploy "$APP" -n "$NS" >/dev/null 2>&1; then
  ready=$(kubectl get deploy "$APP" -n "$NS" -o jsonpath='{.status.readyReplicas}')
  updated=$(kubectl get deploy "$APP" -n "$NS" -o jsonpath='{.status.updatedReplicas}')
  desired=$(kubectl get deploy "$APP" -n "$NS" -o jsonpath='{.spec.replicas}')
  if [[ "${desired:-0}" == "$EXPECTED_REPLICAS" && "${ready:-0}" == "$EXPECTED_REPLICAS" && "${updated:-0}" == "$EXPECTED_REPLICAS" ]]; then
    ok "Deployment ${APP} : ${EXPECTED_REPLICAS}/${EXPECTED_REPLICAS} pods Ready"
  else
    fail "Deployment ${APP} : voulus=${desired:-0}, prêts=${ready:-0}, à jour=${updated:-0} (attendu : ${EXPECTED_REPLICAS} partout)"
  fi
else
  fail "Deployment ${APP} introuvable"
fi

# 2. Pods: 3 active pods (terminating pods excluded), 0 restart
#    Format: name|deletionTimestamp|ready|restartCount
pods=$(kubectl get pods -n "$NS" -l "$SELECTOR" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.deletionTimestamp}{"|"}{.status.containerStatuses[0].ready}{"|"}{.status.containerStatuses[0].restartCount}{"\n"}{end}' 2>/dev/null \
  | awk -F'|' '$1 != "" && $2 == ""')
pod_count=$(printf '%s\n' "$pods" | grep -c . || true)
restarts=$(printf '%s\n' "$pods" | awk -F'|' '{s += $4} END {print s + 0}')
if [[ "$pod_count" == "$EXPECTED_REPLICAS" && "$restarts" == "0" ]]; then
  ok "Pods ${APP} : ${pod_count} pods, 0 restart depuis le dernier rollout"
else
  fail "Pods ${APP} : ${pod_count} pods actifs, ${restarts} restart(s) (attendu : ${EXPECTED_REPLICAS} pods, 0 restart)"
fi

# 3. Service: 3 ready endpoints in the EndpointSlices
if kubectl get svc "$APP" -n "$NS" >/dev/null 2>&1; then
  ready_endpoints=$(kubectl get endpointslices -n "$NS" -l "kubernetes.io/service-name=${APP}" \
    -o jsonpath='{range .items[*].endpoints[*]}{.conditions.ready}{"\n"}{end}' 2>/dev/null \
    | grep -c '^true$' || true)
  if [[ "$ready_endpoints" == "$EXPECTED_REPLICAS" ]]; then
    ok "Service ${APP} : ${ready_endpoints} endpoints prêts"
  else
    fail "Service ${APP} : ${ready_endpoints} endpoint(s) prêt(s) (attendu : ${EXPECTED_REPLICAS})"
  fi
else
  fail "Service ${APP} introuvable"
fi

# 4. Functional test: "/" answers with version 1.0, through the Service
response=$(kubectl exec -n "$NS" "deploy/${APP}" -- wget -qO- -T 5 "http://${APP}/" 2>/dev/null || true)
if [[ "$response" =~ \"version\"[[:space:]]*:[[:space:]]*\"${EXPECTED_VERSION}\" ]]; then
  ok "http://${APP}/ répond avec la version ${EXPECTED_VERSION}"
elif [[ -z "$response" ]]; then
  fail "http://${APP}/ ne répond pas"
else
  fail "http://${APP}/ répond, mais pas avec la version ${EXPECTED_VERSION} : ${response}"
fi

# 5. Secret: contains the BD_MOT_DE_PASSE key
key=$(kubectl get secret "${APP}-secret" -n "$NS" -o jsonpath='{.data.BD_MOT_DE_PASSE}' 2>/dev/null || true)
if [[ -n "$key" ]]; then
  ok "Secret ${APP}-secret : contient BD_MOT_DE_PASSE"
else
  fail "Secret ${APP}-secret : clé BD_MOT_DE_PASSE absente (ou Secret introuvable)"
fi

echo
if (( failures == 0 )); then
  echo "🎉 Atelier 1 réussi."
else
  echo "${failures} critère(s) en échec."
fi
exit $(( failures > 0 ? 1 : 0 ))
