#!/usr/bin/env bash
# Workshop 3 — restores the workshop starting point (final state of
# workshop 2): api-paiements goes back to its version without probes. Idempotent.
# Messages are in French: participants read them.
set -euo pipefail

NS="${NS:-bdc}"
cd "$(dirname "$0")"

echo "Remise à zéro de l'atelier 3 dans le namespace « ${NS} »"

# apply removes the probes and experiment variables: they are in the
# last-applied configuration but no longer in the socle.
kubectl apply -n "$NS" -f depart/00-socle.yaml
kubectl rollout status -n "$NS" deployment/api-paiements --timeout=180s

echo "Terminé."
