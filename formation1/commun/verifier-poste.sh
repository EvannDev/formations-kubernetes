#!/usr/bin/env bash
# Test pré-formation : vérifie que le poste a tout ce qu'il faut pour les ateliers.
# Sortie ✅/⚠️/❌ par critère ; code retour ≠ 0 si au moins un critère échoue.
# Ne nécessite pas sudo. Ne laisse rien derrière lui.
#
# Effet utile : télécharge d'avance les images 1.0 et 1.1 de la formation.
set -uo pipefail

VERSION_K8S_ATTENDUE="v1.36"
IMAGE="ghcr.io/gologic/bdc-formation/app"
NAMESPACES=(bdc bdc-diagnostic)
NS_TEST="verif-poste"
echecs=0

ok()     { echo "✅ $*"; }
alerte() { echo "⚠️  $*"; }
echec()  { echo "❌ $*"; echecs=$((echecs + 1)); }

echo "Vérification du poste pour la formation Kubernetes BDC"
echo

# --- 1. Accès au cluster et version -------------------------------------------

version=$(kubectl version 2>/dev/null | awk '/^Server Version:/ {print $3}')
if [[ -z "$version" ]]; then
  echec "kubectl ne joint pas le cluster. k3s est-il démarré (sudo systemctl status k3s) ? KUBECONFIG=${KUBECONFIG:-non défini}"
  echo
  echo "Inutile d'aller plus loin. Lancez d'abord ./installer-poste.sh"
  exit 1
fi
if [[ "$version" == ${VERSION_K8S_ATTENDUE}.* ]]; then
  ok "Cluster joignable, Kubernetes ${version}"
else
  echec "Kubernetes ${version} : la formation est prévue pour ${VERSION_K8S_ATTENDUE}.x"
fi

# --- 2. Nœud ------------------------------------------------------------------

noeuds=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.conditions[?(@.type=="Ready")].status}{"|"}{.status.allocatable.cpu}{"|"}{.status.allocatable.memory}{"\n"}{end}')
nb_noeuds=$(printf '%s\n' "$noeuds" | grep -c .)
IFS='|' read -r nom_noeud pret cpu memoire <<<"$(printf '%s\n' "$noeuds" | head -1)"
if [[ "$nb_noeuds" == "1" && "$pret" == "True" ]]; then
  ok "Nœud ${nom_noeud} Ready"
else
  echec "Nœuds : ${nb_noeuds} trouvé(s), Ready=${pret:-?} (attendu : 1 nœud Ready)"
fi
# La mémoire allouable est normalement exprimée en Ki
if [[ "$memoire" =~ ^([0-9]+)Ki$ ]]; then
  memoire_mo=$(( BASH_REMATCH[1] / 1024 ))
else
  memoire_mo=0
fi
if [[ "$cpu" =~ ^[0-9]+$ ]] && (( cpu >= 2 && memoire_mo >= 3500 )); then
  ok "Ressources allouables : ${cpu} vCPU, ${memoire_mo} Mo"
else
  alerte "Ressources allouables : ${cpu} vCPU, ${memoire_mo} Mo (minimum : 2 vCPU, 4 Go)"
fi

# --- 3. Namespaces de la formation --------------------------------------------

for ns in "${NAMESPACES[@]}"; do
  if kubectl get namespace "$ns" >/dev/null 2>&1; then
    # Un LimitRange fausserait l'observation de la QoS (atelier 4)
    if [[ -n "$(kubectl get limitrange -n "$ns" -o name 2>/dev/null)" ]]; then
      echec "Namespace ${ns} : contient un LimitRange, à supprimer (fausse l'atelier 4)"
    else
      ok "Namespace ${ns} présent"
    fi
  else
    echec "Namespace ${ns} absent (kubectl create namespace ${ns})"
  fi
done

# --- 4. Réseau (Cilium) et composants fournis par k3s --------------------------

prets=$(kubectl get daemonset cilium -n kube-system -o jsonpath='{.status.numberReady}' 2>/dev/null)
voulus=$(kubectl get daemonset cilium -n kube-system -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null)
if [[ -n "$voulus" && "${prets:-0}" == "$voulus" && "$voulus" -ge 1 ]]; then
  ok "Cilium en marche (${prets}/${voulus} agent)"
else
  echec "Cilium absent ou pas prêt (${prets:-0}/${voulus:-0}) : cilium status"
fi

if command -v cilium >/dev/null; then
  ok "CLI cilium présent ($(cilium version --client 2>/dev/null | grep -o 'cilium-cli: v[0-9.]*' | awk '{print $2}'))"
else
  echec "CLI cilium absent (relancez ./installer-poste.sh)"
fi

for composant in cilium-operator hubble-relay hubble-ui coredns local-path-provisioner metrics-server traefik; do
  prets=$(kubectl get deployment "$composant" -n kube-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  if [[ "${prets:-0}" -ge 1 ]]; then
    ok "${composant} en marche"
  else
    echec "${composant} absent ou pas prêt (kubectl get pods -n kube-system)"
  fi
done

if [[ "$(kubectl get storageclass local-path -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' 2>/dev/null)" == "true" ]]; then
  ok "StorageClass local-path présente (par défaut)"
else
  echec "StorageClass local-path absente ou pas par défaut (atelier 4)"
fi

if kubectl get ingressclass traefik >/dev/null 2>&1; then
  ok "IngressClass traefik présente"
else
  echec "IngressClass traefik absente (atelier 2)"
fi

# metrics-server peut mettre une minute à publier ses premières mesures
top_ok=false
for _ in $(seq 1 12); do
  kubectl top node >/dev/null 2>&1 && { top_ok=true; break; }
  sleep 5
done
if $top_ok; then
  ok "kubectl top node répond (metrics-server)"
else
  echec "kubectl top node ne répond pas après 60 s (ateliers 4 et 5)"
fi

# --- 5. Traefik sur les ports 80/443 du poste ---------------------------------
# Sans Ingress, Traefik doit répondre « 404 page not found ».

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost/ || true)
if [[ "$code" == "404" ]]; then
  ok "Traefik répond sur http://localhost (port 80)"
else
  echec "Traefik ne répond pas sur http://localhost (code : ${code:-aucun}). Un autre service occupe-t-il le port 80 ?"
fi
code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 https://localhost/ || true)
if [[ "$code" == "404" ]]; then
  ok "Traefik répond sur https://localhost (port 443)"
else
  echec "Traefik ne répond pas sur https://localhost (code : ${code:-aucun})"
fi

# --- 6. Image de formation et DNS du cluster ----------------------------------
# Un pod de test, dans un namespace temporaire : son initContainer tire l'image 1.1,
# son conteneur tire l'image 1.0 et résout le nom DNS de l'API Kubernetes.
# Les deux tags restent en cache sur le poste pour les ateliers.

kubectl delete namespace "$NS_TEST" --ignore-not-found --wait=true >/dev/null 2>&1
kubectl create namespace "$NS_TEST" >/dev/null
kubectl apply -n "$NS_TEST" -f - >/dev/null <<EOF
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

# Attente de la fin du pod (téléchargement des images compris), 3 minutes au plus
phase=""
for _ in $(seq 1 90); do
  phase=$(kubectl get pod verif-poste -n "$NS_TEST" -o jsonpath='{.status.phase}' 2>/dev/null)
  raison=$(kubectl get pod verif-poste -n "$NS_TEST" \
    -o jsonpath='{.status.initContainerStatuses[*].state.waiting.reason}{" "}{.status.containerStatuses[*].state.waiting.reason}' 2>/dev/null)
  [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] && break
  [[ "$raison" == *ImagePullBackOff* || "$raison" == *ErrImagePull* || "$raison" == *InvalidImageName* ]] && break
  sleep 2
done

case "$phase" in
  Succeeded)
    ok "Images ${IMAGE}:1.0 et :1.1 téléchargées depuis ghcr.io"
    ok "DNS du cluster fonctionnel"
    ;;
  Failed)
    ok "Images ${IMAGE}:1.0 et :1.1 téléchargées depuis ghcr.io"
    echec "DNS du cluster : nslookup a échoué ($(kubectl logs verif-poste -n "$NS_TEST" 2>/dev/null | tail -1))"
    ;;
  *)
    if [[ "$raison" == *Image* || "$raison" == *ErrImagePull* ]]; then
      message=$(kubectl get events -n "$NS_TEST" --field-selector reason=Failed \
        -o jsonpath='{.items[-1:].message}' 2>/dev/null)
      echec "Téléchargement de l'image impossible depuis ghcr.io : ${message:-$raison}"
      echo "    Proxy d'entreprise ? Voir /etc/systemd/system/k3s.service.env"
    else
      echec "Le pod de test n'a pas terminé en 3 minutes (phase : ${phase:-inconnue})"
    fi
    ;;
esac
kubectl delete namespace "$NS_TEST" --wait=false >/dev/null 2>&1

# --- Bilan --------------------------------------------------------------------

echo
if (( echecs == 0 )); then
  echo "🎉 Poste prêt pour la formation."
else
  echo "${echecs} critère(s) en échec : à corriger avant la formation."
fi
exit $(( echecs > 0 ? 1 : 0 ))
