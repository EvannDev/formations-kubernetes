#!/usr/bin/env bash
# Pre-training check: verifies the machine has everything the workshops need.
# Prints ✅/⚠️/❌ per check; exit code ≠ 0 if at least one check fails.
# Does not need sudo. Leaves nothing behind.
#
# Side effect: pre-pulls the training images 1.0 and 1.1.
# Messages are in French: participants read them.
set -uo pipefail

EXPECTED_K8S_VERSION="v1.36"
IMAGE="ghcr.io/evanndev/formations-kubernetes/app"
NAMESPACES=(bdc bdc-diagnostic)
TEST_NS="verif-poste"
failures=0

ok()   { echo "✅ $*"; }
warn() { echo "⚠️  $*"; }
fail() { echo "❌ $*"; failures=$((failures + 1)); }

echo "Vérification du poste pour la formation Kubernetes BDC"
echo

# --- 1. Cluster access and version --------------------------------------------------

version=$(kubectl version 2>/dev/null | awk '/^Server Version:/ {print $3}')
if [[ -z "$version" ]]; then
  fail "kubectl ne joint pas le cluster. k3s est-il démarré (sudo systemctl status k3s) ? KUBECONFIG=${KUBECONFIG:-non défini}"
  echo
  echo "Inutile d'aller plus loin. Lancez d'abord ./installer-poste.sh"
  exit 1
fi
if [[ "$version" == ${EXPECTED_K8S_VERSION}.* ]]; then
  ok "Cluster joignable, Kubernetes ${version}"
else
  fail "Kubernetes ${version} : la formation est prévue pour ${EXPECTED_K8S_VERSION}.x"
fi

# --- 2. Node ------------------------------------------------------------------------

nodes=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.conditions[?(@.type=="Ready")].status}{"|"}{.status.allocatable.cpu}{"|"}{.status.allocatable.memory}{"\n"}{end}')
node_count=$(printf '%s\n' "$nodes" | grep -c .)
IFS='|' read -r node_name ready cpu memory <<<"$(printf '%s\n' "$nodes" | head -1)"
if [[ "$node_count" == "1" && "$ready" == "True" ]]; then
  ok "Nœud ${node_name} Ready"
else
  fail "Nœuds : ${node_count} trouvé(s), Ready=${ready:-?} (attendu : 1 nœud Ready)"
fi
# Allocatable memory is normally expressed in Ki
if [[ "$memory" =~ ^([0-9]+)Ki$ ]]; then
  memory_mb=$(( BASH_REMATCH[1] / 1024 ))
else
  memory_mb=0
fi
if [[ "$cpu" =~ ^[0-9]+$ ]] && (( cpu >= 2 && memory_mb >= 3500 )); then
  ok "Ressources allouables : ${cpu} vCPU, ${memory_mb} Mo"
else
  warn "Ressources allouables : ${cpu} vCPU, ${memory_mb} Mo (minimum : 2 vCPU, 4 Go)"
fi

# --- 3. Training namespaces ---------------------------------------------------------

for ns in "${NAMESPACES[@]}"; do
  if kubectl get namespace "$ns" >/dev/null 2>&1; then
    # A LimitRange would distort the QoS observation (workshop 4)
    if [[ -n "$(kubectl get limitrange -n "$ns" -o name 2>/dev/null)" ]]; then
      fail "Namespace ${ns} : contient un LimitRange, à supprimer (fausse l'atelier 4)"
    else
      ok "Namespace ${ns} présent"
    fi
  else
    fail "Namespace ${ns} absent (kubectl create namespace ${ns})"
  fi
done

# --- 4. Networking (Cilium) and components shipped with k3s -------------------------

ready_agents=$(kubectl get daemonset cilium -n kube-system -o jsonpath='{.status.numberReady}' 2>/dev/null)
desired_agents=$(kubectl get daemonset cilium -n kube-system -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null)
if [[ -n "$desired_agents" && "${ready_agents:-0}" == "$desired_agents" && "$desired_agents" -ge 1 ]]; then
  ok "Cilium en marche (${ready_agents}/${desired_agents} agent)"
else
  fail "Cilium absent ou pas prêt (${ready_agents:-0}/${desired_agents:-0}) : cilium status"
fi

if command -v cilium >/dev/null; then
  ok "CLI cilium présent ($(cilium version --client 2>/dev/null | grep -o 'cilium-cli: v[0-9.]*' | awk '{print $2}'))"
else
  fail "CLI cilium absent (relancez ./installer-poste.sh)"
fi

for component in cilium-operator hubble-relay hubble-ui coredns local-path-provisioner metrics-server traefik; do
  ready_replicas=$(kubectl get deployment "$component" -n kube-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  if [[ "${ready_replicas:-0}" -ge 1 ]]; then
    ok "${component} en marche"
  else
    fail "${component} absent ou pas prêt (kubectl get pods -n kube-system)"
  fi
done

if [[ "$(kubectl get storageclass local-path -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' 2>/dev/null)" == "true" ]]; then
  ok "StorageClass local-path présente (par défaut)"
else
  fail "StorageClass local-path absente ou pas par défaut (atelier 4)"
fi

if kubectl get ingressclass traefik >/dev/null 2>&1; then
  ok "IngressClass traefik présente"
else
  fail "IngressClass traefik absente (atelier 2)"
fi

# metrics-server may need a minute to publish its first metrics
top_ok=false
for _ in $(seq 1 12); do
  kubectl top node >/dev/null 2>&1 && { top_ok=true; break; }
  sleep 5
done
if $top_ok; then
  ok "kubectl top node répond (metrics-server)"
else
  fail "kubectl top node ne répond pas après 60 s (ateliers 4 et 5)"
fi

# --- 5. Traefik on the machine's ports 80/443 ---------------------------------------
# Without any Ingress, Traefik answers "404 page not found".

# Under WSL, ports exposed by Cilium (eBPF, no listening process) are not
# reachable through localhost: a Traefik port-forward is used instead.
# The failure is only reported as a warning.
if grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
  port_check_failed=warn
  port_hint="Sous WSL, utilisez : kubectl port-forward -n kube-system svc/traefik 8080:80"
else
  port_check_failed=fail
  port_hint="Un autre service occupe-t-il le port ?"
fi

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost/ || true)
if [[ "$code" == "404" ]]; then
  ok "Traefik répond sur http://localhost (port 80)"
else
  $port_check_failed "Traefik ne répond pas sur http://localhost (code : ${code:-aucun}). ${port_hint}"
fi
code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 https://localhost/ || true)
if [[ "$code" == "404" ]]; then
  ok "Traefik répond sur https://localhost (port 443)"
else
  $port_check_failed "Traefik ne répond pas sur https://localhost (code : ${code:-aucun}). ${port_hint}"
fi

# --- 5b. Hubble UI through Traefik --------------------------------------------------
# Temporary port-forward to Traefik: the check does not depend on the
# machine's ports 80/443 and also works under WSL.

if kubectl get ingress hubble-ui -n kube-system >/dev/null 2>&1; then
  local_port=18080
  kubectl port-forward -n kube-system svc/traefik "${local_port}:80" >/dev/null 2>&1 &
  pf_pid=$!
  code=""
  for _ in $(seq 1 10); do
    sleep 1
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
      -H 'Host: hubble.localhost' "http://127.0.0.1:${local_port}/" || true)
    [[ "$code" != "000" ]] && break
  done
  kill "$pf_pid" 2>/dev/null; wait "$pf_pid" 2>/dev/null
  if [[ "$code" == "200" ]]; then
    ok "Hubble UI répond à travers Traefik (http://hubble.localhost)"
  else
    fail "Hubble UI ne répond pas à travers Traefik (code : ${code:-aucun}) : kubectl describe ingress hubble-ui -n kube-system"
  fi
else
  fail "Ingress hubble-ui absent (kubectl apply -f hubble-ui-ingress.yaml)"
fi

# --- 6. Training image and cluster DNS ----------------------------------------------
# A test pod in a temporary namespace: its initContainer pulls image 1.1, its
# container pulls image 1.0 and resolves the Kubernetes API DNS name.
# Both tags stay cached on the machine for the workshops.

kubectl delete namespace "$TEST_NS" --ignore-not-found --wait=true >/dev/null 2>&1
kubectl create namespace "$TEST_NS" >/dev/null
kubectl apply -n "$TEST_NS" -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: verif-poste
spec:
  restartPolicy: Never
  initContainers:
    - name: image-1-1
      image: ${IMAGE}:1.1
      command: ["true"]
  containers:
    - name: image-1-0-et-dns
      image: ${IMAGE}:1.0
      command: ["nslookup", "kubernetes.default.svc.cluster.local"]
EOF

# Wait for the pod to finish (image pulls included), 3 minutes at most
phase=""
for _ in $(seq 1 90); do
  phase=$(kubectl get pod verif-poste -n "$TEST_NS" -o jsonpath='{.status.phase}' 2>/dev/null)
  reason=$(kubectl get pod verif-poste -n "$TEST_NS" \
    -o jsonpath='{.status.initContainerStatuses[*].state.waiting.reason}{" "}{.status.containerStatuses[*].state.waiting.reason}' 2>/dev/null)
  [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] && break
  [[ "$reason" == *ImagePullBackOff* || "$reason" == *ErrImagePull* || "$reason" == *InvalidImageName* ]] && break
  sleep 2
done

case "$phase" in
  Succeeded)
    ok "Images ${IMAGE}:1.0 et :1.1 téléchargées depuis ghcr.io"
    ok "DNS du cluster fonctionnel"
    ;;
  Failed)
    ok "Images ${IMAGE}:1.0 et :1.1 téléchargées depuis ghcr.io"
    fail "DNS du cluster : nslookup a échoué ($(kubectl logs verif-poste -n "$TEST_NS" 2>/dev/null | tail -1))"
    ;;
  *)
    if [[ "$reason" == *Image* || "$reason" == *ErrImagePull* ]]; then
      message=$(kubectl get events -n "$TEST_NS" --field-selector reason=Failed \
        -o jsonpath='{.items[-1:].message}' 2>/dev/null)
      fail "Téléchargement de l'image impossible depuis ghcr.io : ${message:-$reason}"
      echo "    Paquet ghcr.io privé ? Proxy d'entreprise (/etc/systemd/system/k3s.service.env) ?"
    else
      fail "Le pod de test n'a pas terminé en 3 minutes (phase : ${phase:-inconnue})"
    fi
    ;;
esac
kubectl delete namespace "$TEST_NS" --wait=false >/dev/null 2>&1

# --- Summary --------------------------------------------------------------------------

echo
if (( failures == 0 )); then
  echo "🎉 Poste prêt pour la formation."
else
  echo "${failures} critère(s) en échec : à corriger avant la formation."
fi
exit $(( failures > 0 ? 1 : 0 ))
