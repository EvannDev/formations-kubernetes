#!/usr/bin/env bash
# Installe k3s, puis Cilium et Hubble (via le CLI cilium) sur le poste du
# participant, et prépare l'environnement de la formation.
#
# Réseau : Cilium remplace flannel (CNI) et kube-proxy. Le contrôleur de
# NetworkPolicy intégré à k3s est désactivé : c'est Cilium qui les appliquera (F2).
# Observabilité : Hubble, Hubble Relay et Hubble UI sont activés.
#
# Usage : ./installer-poste.sh
#   Variables facultatives :
#     K3S_VERSION          version de k3s (défaut : version épinglée ci-dessous)
#     CILIUM_VERSION       version de Cilium (défaut : version épinglée ci-dessous)
#     CILIUM_CLI_VERSION   version du CLI cilium (défaut : version épinglée ci-dessous)
#     HTTP_PROXY, HTTPS_PROXY, NO_PROXY   proxy d'entreprise, transmis à k3s et au CLI
#
# Idempotent : relancer le script sur un poste déjà prêt ne change rien.
# Nécessite sudo (service systemd, binaires dans /usr/local/bin).
set -euo pipefail

K3S_VERSION="${K3S_VERSION:-v1.36.4+k3s1}"
# Cilium 1.20 prend en charge Kubernetes 1.33 à 1.36
CILIUM_VERSION="${CILIUM_VERSION:-1.20.2}"
CILIUM_CLI_VERSION="${CILIUM_CLI_VERSION:-v0.20.1}"
# Options de k3s requises par Cilium (cf. guide k3s de Cilium)
K3S_OPTIONS=(--flannel-backend=none --disable-network-policy --disable-kube-proxy)
# Valeurs Helm passées à « cilium install »
CILIUM_OPTIONS=(
  # Cilium remplace kube-proxy (k3s lancé avec --disable-kube-proxy) ;
  # il doit donc joindre l'API server directement.
  --set kubeProxyReplacement=true
  --set k8sServiceHost=127.0.0.1
  --set k8sServicePort=6443
  # Adresses des pods tirées du podCIDR attribué par k3s (10.42.0.0/24)
  --set ipam.mode=kubernetes
  # Un seul nœud : un seul opérateur
  --set operator.replicas=1
  # Hubble : observabilité des flux réseau, avec son relais et son interface web
  --set hubble.enabled=true
  --set hubble.relay.enabled=true
  --set hubble.ui.enabled=true
)
NAMESPACES=(bdc bdc-diagnostic)
KUBECONFIG_K3S=/etc/rancher/k3s/k3s.yaml
KUBECONFIG_UTILISATEUR="${HOME}/.kube/config"
MARQUEUR_RC="# formation-bdc : kubeconfig k3s"
# Réseaux internes de k3s, à ne jamais envoyer au proxy
NO_PROXY_K3S="127.0.0.1,localhost,10.42.0.0/16,10.43.0.0/16,.svc,.cluster.local"

info()   { echo "▶ $*"; }
ok()     { echo "✅ $*"; }
alerte() { echo "⚠️  $*"; }
erreur() { echo "❌ $*" >&2; exit 1; }

# --- 1. Vérifications préalables ----------------------------------------------

[[ "$(uname -s)" == "Linux" ]] || erreur "k3s ne s'installe que sous Linux (système détecté : $(uname -s))."
[[ "$EUID" -ne 0 ]] || erreur "Lancez ce script avec votre compte habituel, pas en root : il utilise sudo au besoin."
command -v systemctl >/dev/null || erreur "systemd est requis."
command -v curl >/dev/null || erreur "curl est requis (sudo apt install curl, ou sudo dnf install curl)."
command -v sha256sum >/dev/null || erreur "sha256sum est requis (paquet coreutils)."
sudo -v || erreur "Ce script a besoin des droits sudo."

case "$(uname -m)" in
  x86_64)  architecture=amd64 ;;
  aarch64) architecture=arm64 ;;
  *) erreur "Architecture $(uname -m) non prise en charge (amd64 ou arm64 seulement)." ;;
esac

nb_cpu=$(nproc)
memoire_mo=$(awk '/MemTotal/ {print int($2 / 1024)}' /proc/meminfo)
(( nb_cpu >= 2 )) || alerte "${nb_cpu} vCPU détecté(s) : 2 minimum, 4 recommandés."
(( memoire_mo >= 3800 )) || alerte "${memoire_mo} Mo de RAM : 4 Go minimum, 8 recommandés."

# Cilium exige un noyau 5.10 ou plus récent (4.18 accepté sur RHEL 8.10)
noyau=$(uname -r)
IFS=. read -r noyau_majeur noyau_mineur _ <<<"$noyau"
if (( noyau_majeur < 5 || (noyau_majeur == 5 && ${noyau_mineur%%[!0-9]*} < 10) )); then
  alerte "Noyau ${noyau} : Cilium exige 5.10 ou plus récent (sauf RHEL 8.10)."
fi

version_installee=""
if command -v k3s >/dev/null; then
  version_installee=$(k3s --version | awk 'NR == 1 {print $3}')
  # Un k3s installé avec flannel ne se convertit pas à Cilium sur place
  if ! grep -q -- '--flannel-backend=none' /etc/systemd/system/k3s.service 2>/dev/null; then
    erreur "k3s est déjà installé sans Cilium. Désinstallez-le d'abord : ./desinstaller-poste.sh"
  fi
fi

# --- 2. Installation de k3s ---------------------------------------------------

if [[ "$version_installee" == "$K3S_VERSION" ]]; then
  ok "k3s ${K3S_VERSION} déjà installé."
else
  if [[ -n "$version_installee" ]]; then
    alerte "k3s ${version_installee} est installé ; mise à niveau vers ${K3S_VERSION}."
  else
    # Ports utilisés par k3s : API (6443) et Traefik (80, 443)
    for port in 80 443 6443; do
      if ss -ltnH "sport = :${port}" | grep -q .; then
        erreur "Le port ${port} est déjà utilisé sur ce poste ($(sudo ss -ltnpH "sport = :${port}" | awk '{print $NF}' | head -1)). Libérez-le avant d'installer k3s."
      fi
    done
  fi

  # Transmission du proxy d'entreprise : l'installeur de k3s le recopie dans
  # /etc/systemd/system/k3s.service.env (utilisé pour tirer les images).
  env_proxy=()
  if [[ -n "${HTTPS_PROXY:-${https_proxy:-}}" || -n "${HTTP_PROXY:-${http_proxy:-}}" ]]; then
    no_proxy_final="${NO_PROXY:-${no_proxy:-}}"
    no_proxy_final="${no_proxy_final:+${no_proxy_final},}${NO_PROXY_K3S}"
    env_proxy=(
      "HTTP_PROXY=${HTTP_PROXY:-${http_proxy:-}}"
      "HTTPS_PROXY=${HTTPS_PROXY:-${https_proxy:-}}"
      "NO_PROXY=${no_proxy_final}"
    )
    info "Proxy détecté, transmis à k3s (NO_PROXY=${no_proxy_final})."
  fi

  info "Installation de k3s ${K3S_VERSION} (1 à 2 minutes)…"
  curl -sfL https://get.k3s.io \
    | sudo env "${env_proxy[@]}" INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - server "${K3S_OPTIONS[@]}"
  ok "k3s ${K3S_VERSION} installé."
fi

# --- 3. Kubeconfig de l'utilisateur -------------------------------------------
# On copie le kubeconfig de k3s (lisible par root seulement) dans ~/.kube/config,
# plutôt que de le rendre lisible par tous les comptes du poste.

mkdir -p "${HOME}/.kube"
chmod 700 "${HOME}/.kube"
if [[ -f "$KUBECONFIG_UTILISATEUR" ]] && ! sudo cmp -s "$KUBECONFIG_K3S" "$KUBECONFIG_UTILISATEUR"; then
  sauvegarde="${KUBECONFIG_UTILISATEUR}.avant-formation-$(date +%Y%m%d-%H%M%S)"
  cp "$KUBECONFIG_UTILISATEUR" "$sauvegarde"
  alerte "Un kubeconfig existait déjà : sauvegardé dans ${sauvegarde}."
fi
sudo install -m 600 -o "$(id -u)" -g "$(id -g)" "$KUBECONFIG_K3S" "$KUBECONFIG_UTILISATEUR"
ok "Kubeconfig copié dans ${KUBECONFIG_UTILISATEUR}."

# Le kubectl fourni par k3s lit /etc/rancher/k3s/k3s.yaml si KUBECONFIG n'est pas
# défini : on fixe KUBECONFIG pour tous les nouveaux terminaux.
for rc in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
  [[ -f "$rc" || "$rc" == "${HOME}/.bashrc" ]] || continue
  if ! grep -qF "$MARQUEUR_RC" "$rc" 2>/dev/null; then
    printf '\n%s\nexport KUBECONFIG="$HOME/.kube/config"\n' "$MARQUEUR_RC" >> "$rc"
    info "KUBECONFIG ajouté à ${rc}."
  fi
done
export KUBECONFIG="$KUBECONFIG_UTILISATEUR"

info "Attente de l'API…"
for _ in $(seq 1 60); do
  kubectl get nodes >/dev/null 2>&1 && break
  sleep 2
done
kubectl get nodes >/dev/null 2>&1 || erreur "L'API de k3s ne répond pas. Diagnostic : sudo journalctl -u k3s"

# --- 4. CLI cilium ------------------------------------------------------------
# Binaire officiel, vérifié par sa somme sha256 avant installation.

cli_installee=""
if command -v cilium >/dev/null; then
  cli_installee=$(cilium version --client 2>/dev/null | grep -o 'cilium-cli: v[0-9.]*' | awk '{print $2}' || true)
fi
if [[ "$cli_installee" == "$CILIUM_CLI_VERSION" ]]; then
  ok "CLI cilium ${CILIUM_CLI_VERSION} déjà installé."
else
  info "Installation du CLI cilium ${CILIUM_CLI_VERSION}…"
  archive="cilium-linux-${architecture}.tar.gz"
  url="https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/${archive}"
  temp=$(mktemp -d)
  trap 'rm -rf "$temp"' EXIT
  curl -sfL --output "${temp}/${archive}" "$url" \
    || erreur "Téléchargement impossible : ${url}"
  curl -sfL --output "${temp}/${archive}.sha256sum" "${url}.sha256sum" \
    || erreur "Téléchargement impossible : ${url}.sha256sum"
  (cd "$temp" && sha256sum --check --status "${archive}.sha256sum") \
    || erreur "Somme de contrôle invalide pour ${archive} : installation annulée."
  sudo tar -xzf "${temp}/${archive}" -C /usr/local/bin cilium
  ok "CLI cilium ${CILIUM_CLI_VERSION} installé dans /usr/local/bin."
fi

# --- 5. Cilium et Hubble ------------------------------------------------------
# Le nœud reste NotReady tant que Cilium n'est pas en marche.

cilium_installe=""
if kubectl get daemonset cilium -n kube-system >/dev/null 2>&1; then
  # Image du type quay.io/cilium/cilium:v1.20.2@sha256:…
  cilium_installe=$(kubectl get daemonset cilium -n kube-system \
    -o jsonpath='{.spec.template.spec.containers[0].image}' | sed -E 's/.*:v([0-9.]+).*/\1/')
fi

if [[ -z "$cilium_installe" ]]; then
  info "Installation de Cilium ${CILIUM_VERSION} avec Hubble…"
  cilium install --version "$CILIUM_VERSION" "${CILIUM_OPTIONS[@]}"
elif [[ "$cilium_installe" != "$CILIUM_VERSION" ]] \
  || ! kubectl get deployment hubble-ui -n kube-system >/dev/null 2>&1; then
  info "Mise à jour de Cilium ${cilium_installe} vers ${CILIUM_VERSION} avec Hubble…"
  cilium upgrade --version "$CILIUM_VERSION" "${CILIUM_OPTIONS[@]}"
else
  ok "Cilium ${CILIUM_VERSION} et Hubble déjà installés."
fi

info "Attente de Cilium et Hubble (2 à 5 minutes)…"
cilium status --wait --wait-duration 10m >/dev/null \
  || erreur "Cilium n'est pas prêt. Diagnostic : cilium status ; kubectl get pods -n kube-system"
ok "Cilium ${CILIUM_VERSION} prêt (Hubble, Relay et UI compris)."

kubectl wait --for=condition=Ready node --all --timeout=120s >/dev/null
ok "Nœud Ready."

# --- 6. Composants fournis par k3s --------------------------------------------
# Traefik est installé par un job Helm après le démarrage : son Deployment
# peut mettre une minute à apparaître.

for composant in coredns local-path-provisioner metrics-server traefik; do
  info "Attente de ${composant}…"
  for _ in $(seq 1 90); do
    kubectl get deployment "$composant" -n kube-system >/dev/null 2>&1 && break
    sleep 2
  done
  kubectl rollout status deployment "$composant" -n kube-system --timeout=180s >/dev/null \
    || erreur "${composant} n'a pas démarré. Diagnostic : kubectl get pods -n kube-system"
  ok "${composant} prêt."
done

# --- 7. Ingress de Hubble UI --------------------------------------------------

kubectl apply -f "$(dirname "$0")/hubble-ui-ingress.yaml" >/dev/null
ok "Hubble UI exposée par Traefik sur http://hubble.localhost"

# --- 8. Namespaces de la formation --------------------------------------------

for ns in "${NAMESPACES[@]}"; do
  kubectl create namespace "$ns" --dry-run=client -o yaml \
    | kubectl label --local -f - app.kubernetes.io/part-of=bdc-paiements -o yaml \
    | kubectl apply -f - >/dev/null
  ok "Namespace ${ns} prêt."
done

echo
ok "Poste prêt. Ouvrez un nouveau terminal (pour KUBECONFIG), puis lancez :"
echo "   ./verifier-poste.sh"
echo
echo "Interface Hubble (flux réseau en direct) : http://hubble.localhost"
echo "   (ou « cilium hubble ui », puis http://localhost:12000)"
