#!/usr/bin/env bash
# Workshop 5 — deploys the five faulty apps in the bdc-diagnostic namespace.
# Idempotent: running it again puts the faults back.
# Messages are in French: participants read them.
set -euo pipefail

NS="bdc-diagnostic"
cd "$(dirname "$0")"

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -n "$NS" -f depart/pannes.yaml >/dev/null

echo "✅ Cinq applis déployées dans le namespace « ${NS} »."
echo
echo "Laissez-leur 2 minutes, puis commencez par :"
echo "   kubectl get pods -n ${NS}"
