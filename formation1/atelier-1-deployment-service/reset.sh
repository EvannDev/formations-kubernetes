#!/usr/bin/env bash
# Atelier 1 — supprime les objets de l'atelier dans $NS (idempotent).
set -euo pipefail

NS="${NS:-bdc}"

echo "Remise à zéro de l'atelier 1 dans le namespace « ${NS} »"

kubectl delete -n "$NS" --ignore-not-found \
  deployment/api-paiements \
  service/api-paiements \
  configmap/api-paiements-config \
  secret/api-paiements-secret

# Pods orphelins : pod relabellisé « quarantaine » (étape de réconciliation)
# et pod de test lancé avec « kubectl run test ».
kubectl delete pod -n "$NS" --ignore-not-found -l app.kubernetes.io/name=quarantaine
kubectl delete pod -n "$NS" --ignore-not-found test

echo "Terminé."
