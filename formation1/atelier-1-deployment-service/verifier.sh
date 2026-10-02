#!/usr/bin/env bash
# Atelier 1 — vérifie l'état final de api-paiements dans $NS.
# Sortie ✅/❌ par critère ; code retour ≠ 0 si au moins un critère échoue.
set -uo pipefail

NS="${NS:-bdc}"
APPLI="api-paiements"
SELECTEUR="app.kubernetes.io/name=${APPLI}"
VERSION_ATTENDUE="1.0"
REPLICAS_ATTENDUS=3
echecs=0

ok()    { echo "✅ $*"; }
echec() { echo "❌ $*"; echecs=$((echecs + 1)); }

echo "Atelier 1 — vérification dans le namespace « ${NS} »"
echo

if ! kubectl get namespace "$NS" >/dev/null 2>&1; then
  echec "Le namespace ${NS} n'existe pas (avez-vous fait « export NS=bdc » ?)"
  exit 1
fi

# 1. Deployment : 3 réplicas prêts et à jour
if kubectl get deploy "$APPLI" -n "$NS" >/dev/null 2>&1; then
  prets=$(kubectl get deploy "$APPLI" -n "$NS" -o jsonpath='{.status.readyReplicas}')
  a_jour=$(kubectl get deploy "$APPLI" -n "$NS" -o jsonpath='{.status.updatedReplicas}')
  voulus=$(kubectl get deploy "$APPLI" -n "$NS" -o jsonpath='{.spec.replicas}')
  if [[ "${voulus:-0}" == "$REPLICAS_ATTENDUS" && "${prets:-0}" == "$REPLICAS_ATTENDUS" && "${a_jour:-0}" == "$REPLICAS_ATTENDUS" ]]; then
    ok "Deployment ${APPLI} : ${REPLICAS_ATTENDUS}/${REPLICAS_ATTENDUS} pods Ready"
  else
    echec "Deployment ${APPLI} : voulus=${voulus:-0}, prêts=${prets:-0}, à jour=${a_jour:-0} (attendu : ${REPLICAS_ATTENDUS} partout)"
  fi
else
  echec "Deployment ${APPLI} introuvable"
fi

# 2. Pods : 3 pods actifs (hors pods en cours de suppression), 0 restart
#    Format : nom|deletionTimestamp|ready|restartCount
lignes=$(kubectl get pods -n "$NS" -l "$SELECTEUR" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.deletionTimestamp}{"|"}{.status.containerStatuses[0].ready}{"|"}{.status.containerStatuses[0].restartCount}{"\n"}{end}' 2>/dev/null \
  | awk -F'|' '$1 != "" && $2 == ""')
nb_pods=$(printf '%s\n' "$lignes" | grep -c . || true)
restarts=$(printf '%s\n' "$lignes" | awk -F'|' '{s += $4} END {print s + 0}')
if [[ "$nb_pods" == "$REPLICAS_ATTENDUS" && "$restarts" == "0" ]]; then
  ok "Pods ${APPLI} : ${nb_pods} pods, 0 restart depuis le dernier rollout"
else
  echec "Pods ${APPLI} : ${nb_pods} pods actifs, ${restarts} restart(s) (attendu : ${REPLICAS_ATTENDUS} pods, 0 restart)"
fi

# 3. Service : 3 endpoints prêts dans les EndpointSlices
if kubectl get svc "$APPLI" -n "$NS" >/dev/null 2>&1; then
  endpoints_prets=$(kubectl get endpointslices -n "$NS" -l "kubernetes.io/service-name=${APPLI}" \
    -o jsonpath='{range .items[*].endpoints[*]}{.conditions.ready}{"\n"}{end}' 2>/dev/null \
    | grep -c '^true$' || true)
  if [[ "$endpoints_prets" == "$REPLICAS_ATTENDUS" ]]; then
    ok "Service ${APPLI} : ${endpoints_prets} endpoints prêts"
  else
    echec "Service ${APPLI} : ${endpoints_prets} endpoint(s) prêt(s) (attendu : ${REPLICAS_ATTENDUS})"
  fi
else
  echec "Service ${APPLI} introuvable"
fi

# 4. Test fonctionnel : « / » répond avec la version 1.0, en passant par le Service
reponse=$(kubectl exec -n "$NS" "deploy/${APPLI}" -- wget -qO- -T 5 "http://${APPLI}/" 2>/dev/null || true)
if [[ "$reponse" =~ \"version\"[[:space:]]*:[[:space:]]*\"${VERSION_ATTENDUE}\" ]]; then
  ok "http://${APPLI}/ répond avec la version ${VERSION_ATTENDUE}"
elif [[ -z "$reponse" ]]; then
  echec "http://${APPLI}/ ne répond pas"
else
  echec "http://${APPLI}/ répond, mais pas avec la version ${VERSION_ATTENDUE} : ${reponse}"
fi

# 5. Secret : contient la clé BD_MOT_DE_PASSE
cle=$(kubectl get secret "${APPLI}-secret" -n "$NS" -o jsonpath='{.data.BD_MOT_DE_PASSE}' 2>/dev/null || true)
if [[ -n "$cle" ]]; then
  ok "Secret ${APPLI}-secret : contient BD_MOT_DE_PASSE"
else
  echec "Secret ${APPLI}-secret : clé BD_MOT_DE_PASSE absente (ou Secret introuvable)"
fi

echo
if (( echecs == 0 )); then
  echo "🎉 Atelier 1 réussi."
else
  echo "${echecs} critère(s) en échec."
fi
exit $(( echecs > 0 ? 1 : 0 ))
