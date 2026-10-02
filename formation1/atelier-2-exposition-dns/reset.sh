#!/usr/bin/env bash
# Workshop 2 — deletes the workshop objects in $NS and restores the workshop
# starting point (final state of workshop 1). Idempotent.
# Messages are in French: participants read them.
set -euo pipefail

NS="${NS:-bdc}"
cd "$(dirname "$0")"

echo "Remise à zéro de l'atelier 2 dans le namespace « ${NS} »"

kubectl delete -n "$NS" --ignore-not-found \
  deployment/portail-client \
  service/portail-client \
  ingress/portail-client \
  service/portail-nodeport

# Bonus objects
kubectl delete namespace bdc-voisin --ignore-not-found

# Starting point: workshop 1 final state, including the original
# api-paiements Service (replaced by 02-service-api.yaml during this workshop)
kubectl apply -n "$NS" -f depart/00-socle.yaml

echo "Terminé."
