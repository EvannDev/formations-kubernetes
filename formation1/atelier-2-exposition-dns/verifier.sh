#!/usr/bin/env bash
# Workshop 2 — checks that portail-client reaches api-paiements and is exposed
# by the Ingress, in $NS.
# Prints ✅/❌ per check; exit code ≠ 0 if at least one check fails.
# Messages are in French: participants read them.
set -uo pipefail

NS="${NS:-bdc}"
FRONTEND="portail-client"
BACKEND="api-paiements"
INGRESS_HOST="portail.localhost"
EXPECTED_FRONTEND_REPLICAS=2
failures=0

ok()   { echo "✅ $*"; }
fail() { echo "❌ $*"; failures=$((failures + 1)); }

echo "Atelier 2 — vérification dans le namespace « ${NS} »"
echo

if ! kubectl get namespace "$NS" >/dev/null 2>&1; then
  fail "Le namespace ${NS} n'existe pas (avez-vous fait « export NS=bdc » ?)"
  exit 1
fi

# 1. portail-client: 2 replicas ready
ready=$(kubectl get deploy "$FRONTEND" -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
if [[ "${ready:-0}" == "$EXPECTED_FRONTEND_REPLICAS" ]]; then
  ok "Deployment ${FRONTEND} : ${EXPECTED_FRONTEND_REPLICAS}/${EXPECTED_FRONTEND_REPLICAS} pods Ready"
else
  fail "Deployment ${FRONTEND} : ${ready:-0} pod(s) Ready (attendu : ${EXPECTED_FRONTEND_REPLICAS})"
fi

# 2. api-paiements Service: endpoints point to the port the app listens on
endpoint_ports=$(kubectl get endpointslices -n "$NS" -l "kubernetes.io/service-name=${BACKEND}" \
  -o jsonpath='{range .items[*]}{.ports[*].port}{"\n"}{end}' 2>/dev/null | sort -u | tr '\n' ' ')
if [[ "$endpoint_ports" == "8080 " ]]; then
  ok "Service ${BACKEND} : trafic envoyé au port 8080 des pods"
else
  fail "Service ${BACKEND} : trafic envoyé au(x) port(s) « ${endpoint_ports% } » des pods (attendu : 8080)"
fi

# 3. Functional test: /appel on portail-client returns api-paiements' answer
response=$(kubectl exec -n "$NS" "deploy/${FRONTEND}" -- wget -qO- -T 10 "http://localhost:8080/appel" 2>/dev/null || true)
if [[ "$response" =~ \"statut_amont\":200 && "$response" =~ \"appli\":\"${BACKEND}\" ]]; then
  ok "${FRONTEND}/appel reçoit la réponse de ${BACKEND}"
else
  # On error, wget prints no body: ask for the detail
  fail "${FRONTEND}/appel n'obtient pas de réponse de ${BACKEND} (détail : kubectl exec deploy/${FRONTEND} -- wget -qO- http://localhost:8080/appel)"
fi

# 4. Ingress: answers through Traefik with the portail-client page.
#    Temporary port-forward to Traefik: works on native Linux and under WSL.
if kubectl get ingress "$FRONTEND" -n "$NS" >/dev/null 2>&1; then
  local_port=18081
  kubectl port-forward -n kube-system svc/traefik "${local_port}:80" >/dev/null 2>&1 &
  pf_pid=$!
  code="" body=""
  for _ in $(seq 1 10); do
    sleep 1
    body=$(curl -s --max-time 5 -H "Host: ${INGRESS_HOST}" -w '\n%{http_code}' "http://127.0.0.1:${local_port}/" || true)
    code=${body##*$'\n'}
    [[ "$code" != "000" && -n "$code" ]] && break
  done
  kill "$pf_pid" 2>/dev/null; wait "$pf_pid" 2>/dev/null
  if [[ "$code" == "200" && "$body" =~ \"appli\":\"${FRONTEND}\" ]]; then
    ok "Ingress ${FRONTEND} : http://${INGRESS_HOST} répond HTTP 200 avec la page de ${FRONTEND}"
  else
    fail "Ingress ${FRONTEND} : http://${INGRESS_HOST} répond HTTP ${code:-aucun} (attendu : 200 de ${FRONTEND}) ; voir kubectl describe ingress ${FRONTEND}"
  fi
else
  fail "Ingress ${FRONTEND} introuvable"
fi

echo
if (( failures == 0 )); then
  echo "🎉 Atelier 2 réussi."
else
  echo "${failures} critère(s) en échec."
fi
exit $(( failures > 0 ? 1 : 0 ))
