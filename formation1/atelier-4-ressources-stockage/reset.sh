#!/usr/bin/env bash
# Workshop 4 — deletes the workshop objects in $NS and restores the workshop
# starting point (final state of workshop 3). Idempotent.
# ⚠️ Deletes the cache-sessions data.
# Messages are in French: participants read them.
set -euo pipefail

NS="${NS:-bdc}"
cd "$(dirname "$0")"

echo "Remise à zéro de l'atelier 4 dans le namespace « ${NS} »"

kubectl delete pod -n "$NS" --ignore-not-found qos-besteffort qos-burstable qos-guaranteed

# Deployment first: a PVC still used by a pod stays in Terminating
kubectl delete deployment -n "$NS" --ignore-not-found --wait=true cache-sessions
kubectl delete pvc -n "$NS" --ignore-not-found cache-sessions

# apply removes the resources section of api-paiements: it is in the
# last-applied configuration but no longer in the socle.
kubectl apply -n "$NS" -f depart/00-socle.yaml
kubectl rollout status -n "$NS" deployment/api-paiements --timeout=240s

echo "Terminé."
