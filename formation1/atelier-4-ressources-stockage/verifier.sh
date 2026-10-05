#!/usr/bin/env bash
# Workshop 4 — checks resources and QoS of api-paiements, the QoS trio and the
# persistent storage of cache-sessions, in $NS.
# Run it BEFORE step 6 (which deletes the storage on purpose).
# Prints ✅/❌ per check; exit code ≠ 0 if at least one check fails.
# Messages are in French: participants read them.
set -uo pipefail

NS="${NS:-bdc}"
API="api-paiements"
CACHE="cache-sessions"
TEST_FILE="/donnees/session.txt"
EXPECTED_REPLICAS=3
EXPECTED_BALLOON_MB=150
failures=0

ok()   { echo "✅ $*"; }
fail() { echo "❌ $*"; failures=$((failures + 1)); }

echo "Atelier 4 — vérification dans le namespace « ${NS} »"
echo

if ! kubectl get deploy "$API" -n "$NS" >/dev/null 2>&1; then
  fail "Deployment ${API} introuvable dans ${NS} (avez-vous fait « export NS=bdc » ?)"
  exit 1
fi

# --- api-paiements --------------------------------------------------------------

# 1. Rollout finished: 3 replicas ready and up to date
ready=$(kubectl get deploy "$API" -n "$NS" -o jsonpath='{.status.readyReplicas}')
updated=$(kubectl get deploy "$API" -n "$NS" -o jsonpath='{.status.updatedReplicas}')
total=$(kubectl get deploy "$API" -n "$NS" -o jsonpath='{.status.replicas}')
if [[ "${ready:-0}" == "$EXPECTED_REPLICAS" && "${updated:-0}" == "$EXPECTED_REPLICAS" && "${total:-0}" == "$EXPECTED_REPLICAS" ]]; then
  ok "Deployment ${API} : ${EXPECTED_REPLICAS}/${EXPECTED_REPLICAS} pods Ready, rollout terminé"
else
  fail "Deployment ${API} : prêts=${ready:-0}, à jour=${updated:-0}, total=${total:-0} (attendu : ${EXPECTED_REPLICAS} partout ; pod Pending ?)"
fi

# 2. The memory cache is still there (it is the app's reality, not a defect)
balloon=$(kubectl get deploy "$API" -n "$NS" \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="BALLON_MEMOIRE_MO")].value}')
if [[ "$balloon" == "$EXPECTED_BALLOON_MB" ]]; then
  ok "Cache mémoire conservé (BALLON_MEMOIRE_MO=${EXPECTED_BALLOON_MB})"
else
  fail "BALLON_MEMOIRE_MO vaut « ${balloon:-absente} » (attendu : ${EXPECTED_BALLOON_MB}) : on dimensionne l'appli, on ne la change pas"
fi

# 3. Active pods: no restart, no OOMKilled, QoS Burstable
#    Format: deletionTimestamp|restartCount|lastTerminationReason|qosClass
pods=$(kubectl get pods -n "$NS" -l "app.kubernetes.io/name=${API}" \
  -o jsonpath='{range .items[*]}{.metadata.deletionTimestamp}{"|"}{.status.containerStatuses[0].restartCount}{"|"}{.status.containerStatuses[0].lastState.terminated.reason}{"|"}{.status.qosClass}{"\n"}{end}' 2>/dev/null \
  | awk -F'|' '$1 == ""')
restarts=$(printf '%s\n' "$pods" | awk -F'|' '{s += $2} END {print s + 0}')
oom=$(printf '%s\n' "$pods" | grep -c '|OOMKilled|' || true)
if [[ "$restarts" == "0" && "$oom" == "0" ]]; then
  ok "Pods ${API} : 0 restart, aucun OOMKilled"
else
  fail "Pods ${API} : ${restarts} restart(s), ${oom} pod(s) OOMKilled (attendu : 0 ; voir kubectl describe pod, section Last State)"
fi
qos_classes=$(printf '%s\n' "$pods" | awk -F'|' 'NF {print $4}' | sort -u | tr '\n' ' ')
if [[ "$qos_classes" == "Burstable " ]]; then
  ok "Pods ${API} : QoS Burstable"
else
  fail "Pods ${API} : QoS « ${qos_classes% } » (attendu : Burstable)"
fi

# --- QoS trio ---------------------------------------------------------------------

for expected in qos-besteffort:BestEffort qos-burstable:Burstable qos-guaranteed:Guaranteed; do
  pod=${expected%%:*}
  qos=$(kubectl get pod "$pod" -n "$NS" -o jsonpath='{.status.qosClass}' 2>/dev/null)
  if [[ "$qos" == "${expected##*:}" ]]; then
    ok "Pod ${pod} : QoS ${qos}"
  else
    fail "Pod ${pod} : QoS « ${qos:-pod absent} » (attendu : ${expected##*:} ; kubectl apply -f depart/02-qos-trio.yaml)"
  fi
done

# --- cache-sessions -----------------------------------------------------------------

# 4. PVC bound to a volume
pvc_phase=$(kubectl get pvc "$CACHE" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
if [[ "$pvc_phase" == "Bound" ]]; then
  ok "PVC ${CACHE} : Bound ($(kubectl get pvc "$CACHE" -n "$NS" -o jsonpath='{.spec.storageClassName}'))"
else
  fail "PVC ${CACHE} : « ${pvc_phase:-absent} » (attendu : Bound ; voir kubectl describe pvc ${CACHE})"
fi

# 5. Test file present AND older than the current pod: it survived a recreation
pod_start=$(kubectl get pods -n "$NS" -l "app.kubernetes.io/name=${CACHE}" \
  -o jsonpath='{.items[0].status.startTime}' 2>/dev/null)
file_mtime=$(kubectl exec -n "$NS" "deploy/${CACHE}" -- stat -c %Y "$TEST_FILE" 2>/dev/null || true)
if [[ -z "$file_mtime" ]]; then
  fail "Fichier ${TEST_FILE} absent du pod ${CACHE} (étape 5)"
elif [[ -n "$pod_start" ]] && (( file_mtime < $(date -d "$pod_start" +%s) )); then
  ok "Fichier ${TEST_FILE} présent et antérieur au pod actuel : il a survécu à la recréation du pod"
else
  fail "Fichier ${TEST_FILE} présent, mais écrit par le pod actuel : supprimez le pod et vérifiez qu'il est toujours là (étape 5)"
fi

echo
if (( failures == 0 )); then
  echo "🎉 Atelier 4 réussi. Passez à l'étape 6 (elle supprime le stockage, c'est voulu)."
else
  echo "${failures} critère(s) en échec."
fi
exit $(( failures > 0 ? 1 : 0 ))
