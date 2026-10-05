#!/usr/bin/env bash
# Workshop 5 — removes the five apps and undoes node-level workarounds.
# Sheets in fiches/ are kept (participants' work).
# Run ./deployer-pannes.sh afterwards to start over.
# Messages are in French: participants read them.
set -euo pipefail

NS="bdc-diagnostic"
cd "$(dirname "$0")"

echo "Remise à zéro de l'atelier 5 dans le namespace « ${NS} »"

kubectl delete -n "$NS" --ignore-not-found -f depart/pannes.yaml

# Workaround some participants use for moteur-scoring: labeling the node
kubectl label node --all bdc.ca/pool- >/dev/null 2>&1 || true

echo "Terminé. Pour recommencer : ./deployer-pannes.sh (vos fiches sont conservées)."
