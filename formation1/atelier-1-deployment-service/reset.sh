#!/usr/bin/env bash
# Workshop 1 — deletes the workshop objects in $NS (idempotent).
# Messages are in French: participants read them.
set -euo pipefail

NS="${NS:-bdc}"

echo "Remise à zéro de l'atelier 1 dans le namespace « ${NS} »"

kubectl delete -n "$NS" --ignore-not-found \
  deployment/api-paiements \
  service/api-paiements \
  configmap/api-paiements-config \
  secret/api-paiements-secret

# Orphan pods: the pod relabeled "quarantaine" (reconciliation step)
# and the test pod started with "kubectl run test".
kubectl delete pod -n "$NS" --ignore-not-found -l app.kubernetes.io/name=quarantaine
kubectl delete pod -n "$NS" --ignore-not-found test

echo "Terminé."
