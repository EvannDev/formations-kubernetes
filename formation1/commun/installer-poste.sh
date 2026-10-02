#!/usr/bin/env bash
# Installs k3s, then Cilium and Hubble (through the cilium CLI) on the
# participant's machine, and prepares the training environment.
#
# Networking: Cilium replaces flannel (CNI) and kube-proxy. k3s' embedded
# NetworkPolicy controller is disabled: Cilium will enforce policies (F2).
# Observability: Hubble, Hubble Relay and Hubble UI are enabled; Hubble UI is
# exposed by Traefik on http://hubble.localhost.
#
# Usage: ./installer-poste.sh
#   Optional variables:
#     K3S_VERSION          k3s version (default: pinned below)
#     CILIUM_VERSION       Cilium version (default: pinned below)
#     CILIUM_CLI_VERSION   cilium CLI version (default: pinned below)
#     HTTP_PROXY, HTTPS_PROXY, NO_PROXY   corporate proxy, passed to k3s and the CLI
#
# Idempotent: running it again on a ready machine changes nothing.
# Requires sudo (systemd service, binaries in /usr/local/bin).
# Messages are in French: participants read them.
set -euo pipefail

K3S_VERSION="${K3S_VERSION:-v1.36.4+k3s1}"
# Cilium 1.20 supports Kubernetes 1.33 to 1.36
CILIUM_VERSION="${CILIUM_VERSION:-1.20.2}"
CILIUM_CLI_VERSION="${CILIUM_CLI_VERSION:-v0.20.1}"
# k3s flags required by Cilium (see Cilium's k3s guide)
K3S_FLAGS=(--flannel-backend=none --disable-network-policy --disable-kube-proxy)
# Helm values passed to "cilium install"
CILIUM_FLAGS=(
  # Cilium replaces kube-proxy (k3s runs with --disable-kube-proxy),
  # so it must reach the API server directly.
  --set kubeProxyReplacement=true
  --set k8sServiceHost=127.0.0.1
  --set k8sServicePort=6443
  # Pod IPs taken from the podCIDR assigned by k3s (10.42.0.0/24)
  --set ipam.mode=kubernetes
  # Single node: single operator
  --set operator.replicas=1
  # Hubble: network flow observability, with its relay and web UI
  --set hubble.enabled=true
  --set hubble.relay.enabled=true
  --set hubble.ui.enabled=true
)
NAMESPACES=(bdc bdc-diagnostic)
K3S_KUBECONFIG=/etc/rancher/k3s/k3s.yaml
USER_KUBECONFIG="${HOME}/.kube/config"
# Written to the shell rc files; desinstaller-poste.sh looks for it verbatim
RC_MARKER="# formation-bdc : kubeconfig k3s"
# k3s internal networks, never sent to the proxy
K3S_NO_PROXY="127.0.0.1,localhost,10.42.0.0/16,10.43.0.0/16,.svc,.cluster.local"

info() { echo "▶ $*"; }
ok()   { echo "✅ $*"; }
warn() { echo "⚠️  $*"; }
die()  { echo "❌ $*" >&2; exit 1; }

# --- 1. Preflight checks ----------------------------------------------------------

[[ "$(uname -s)" == "Linux" ]] || die "k3s ne s'installe que sous Linux (système détecté : $(uname -s))."
[[ "$EUID" -ne 0 ]] || die "Lancez ce script avec votre compte habituel, pas en root : il utilise sudo au besoin."
command -v systemctl >/dev/null || die "systemd est requis."
command -v curl >/dev/null || die "curl est requis (sudo apt install curl, ou sudo dnf install curl)."
command -v sha256sum >/dev/null || die "sha256sum est requis (paquet coreutils)."
sudo -v || die "Ce script a besoin des droits sudo."

case "$(uname -m)" in
  x86_64)  arch=amd64 ;;
  aarch64) arch=arm64 ;;
  *) die "Architecture $(uname -m) non prise en charge (amd64 ou arm64 seulement)." ;;
esac

cpu_count=$(nproc)
memory_mb=$(awk '/MemTotal/ {print int($2 / 1024)}' /proc/meminfo)
(( cpu_count >= 2 )) || warn "${cpu_count} vCPU détecté(s) : 2 minimum, 4 recommandés."
(( memory_mb >= 3800 )) || warn "${memory_mb} Mo de RAM : 4 Go minimum, 8 recommandés."

# Cilium requires kernel 5.10 or newer (4.18 accepted on RHEL 8.10)
kernel=$(uname -r)
IFS=. read -r kernel_major kernel_minor _ <<<"$kernel"
if (( kernel_major < 5 || (kernel_major == 5 && ${kernel_minor%%[!0-9]*} < 10) )); then
  warn "Noyau ${kernel} : Cilium exige 5.10 ou plus récent (sauf RHEL 8.10)."
fi

installed_version=""
if command -v k3s >/dev/null; then
  installed_version=$(k3s --version | awk 'NR == 1 {print $3}')
  # A k3s installed with flannel cannot be switched to Cilium in place
  if ! grep -q -- '--flannel-backend=none' /etc/systemd/system/k3s.service 2>/dev/null; then
    die "k3s est déjà installé sans Cilium. Désinstallez-le d'abord : ./desinstaller-poste.sh"
  fi
fi

# --- 2. k3s -------------------------------------------------------------------------

if [[ "$installed_version" == "$K3S_VERSION" ]]; then
  ok "k3s ${K3S_VERSION} déjà installé."
else
  if [[ -n "$installed_version" ]]; then
    warn "k3s ${installed_version} est installé ; mise à niveau vers ${K3S_VERSION}."
  else
    # Ports used by k3s: API (6443) and Traefik (80, 443)
    for port in 80 443 6443; do
      if ss -ltnH "sport = :${port}" | grep -q .; then
        die "Le port ${port} est déjà utilisé sur ce poste ($(sudo ss -ltnpH "sport = :${port}" | awk '{print $NF}' | head -1)). Libérez-le avant d'installer k3s."
      fi
    done
  fi

  # Corporate proxy: the k3s installer copies it to
  # /etc/systemd/system/k3s.service.env (used to pull images).
  proxy_env=()
  if [[ -n "${HTTPS_PROXY:-${https_proxy:-}}" || -n "${HTTP_PROXY:-${http_proxy:-}}" ]]; then
    no_proxy_value="${NO_PROXY:-${no_proxy:-}}"
    no_proxy_value="${no_proxy_value:+${no_proxy_value},}${K3S_NO_PROXY}"
    proxy_env=(
      "HTTP_PROXY=${HTTP_PROXY:-${http_proxy:-}}"
      "HTTPS_PROXY=${HTTPS_PROXY:-${https_proxy:-}}"
      "NO_PROXY=${no_proxy_value}"
    )
    info "Proxy détecté, transmis à k3s (NO_PROXY=${no_proxy_value})."
  fi

  info "Installation de k3s ${K3S_VERSION} (1 à 2 minutes)…"
  curl -sfL https://get.k3s.io \
    | sudo env "${proxy_env[@]}" INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - server "${K3S_FLAGS[@]}"
  ok "k3s ${K3S_VERSION} installé."
fi

# --- 3. User kubeconfig -------------------------------------------------------------
# Copy the k3s kubeconfig (root-only) to ~/.kube/config rather than making it
# readable by every account on the machine.

mkdir -p "${HOME}/.kube"
chmod 700 "${HOME}/.kube"
if [[ -f "$USER_KUBECONFIG" ]] && ! sudo cmp -s "$K3S_KUBECONFIG" "$USER_KUBECONFIG"; then
  # Suffix looked up by desinstaller-poste.sh to restore the previous file
  backup="${USER_KUBECONFIG}.avant-formation-$(date +%Y%m%d-%H%M%S)"
  cp "$USER_KUBECONFIG" "$backup"
  warn "Un kubeconfig existait déjà : sauvegardé dans ${backup}."
fi
sudo install -m 600 -o "$(id -u)" -g "$(id -g)" "$K3S_KUBECONFIG" "$USER_KUBECONFIG"
ok "Kubeconfig copié dans ${USER_KUBECONFIG}."

# The kubectl shipped with k3s reads /etc/rancher/k3s/k3s.yaml when KUBECONFIG
# is unset: set KUBECONFIG for every new terminal.
for rc in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
  [[ -f "$rc" || "$rc" == "${HOME}/.bashrc" ]] || continue
  if ! grep -qF "$RC_MARKER" "$rc" 2>/dev/null; then
    printf '\n%s\nexport KUBECONFIG="$HOME/.kube/config"\n' "$RC_MARKER" >> "$rc"
    info "KUBECONFIG ajouté à ${rc}."
  fi
done
export KUBECONFIG="$USER_KUBECONFIG"

info "Attente de l'API…"
for _ in $(seq 1 60); do
  kubectl get nodes >/dev/null 2>&1 && break
  sleep 2
done
kubectl get nodes >/dev/null 2>&1 || die "L'API de k3s ne répond pas. Diagnostic : sudo journalctl -u k3s"

# --- 4. cilium CLI ------------------------------------------------------------------
# Official binary, checked against its sha256 before installation.

installed_cli=""
if command -v cilium >/dev/null; then
  installed_cli=$(cilium version --client 2>/dev/null | grep -o 'cilium-cli: v[0-9.]*' | awk '{print $2}' || true)
fi
if [[ "$installed_cli" == "$CILIUM_CLI_VERSION" ]]; then
  ok "CLI cilium ${CILIUM_CLI_VERSION} déjà installé."
else
  info "Installation du CLI cilium ${CILIUM_CLI_VERSION}…"
  archive="cilium-linux-${arch}.tar.gz"
  url="https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/${archive}"
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  curl -sfL --output "${tmp}/${archive}" "$url" \
    || die "Téléchargement impossible : ${url}"
  curl -sfL --output "${tmp}/${archive}.sha256sum" "${url}.sha256sum" \
    || die "Téléchargement impossible : ${url}.sha256sum"
  (cd "$tmp" && sha256sum --check --status "${archive}.sha256sum") \
    || die "Somme de contrôle invalide pour ${archive} : installation annulée."
  sudo tar -xzf "${tmp}/${archive}" -C /usr/local/bin cilium
  ok "CLI cilium ${CILIUM_CLI_VERSION} installé dans /usr/local/bin."
fi

# --- 5. Cilium and Hubble -----------------------------------------------------------
# The node stays NotReady until Cilium is running.

installed_cilium=""
if kubectl get daemonset cilium -n kube-system >/dev/null 2>&1; then
  # Image like quay.io/cilium/cilium:v1.20.2@sha256:…
  installed_cilium=$(kubectl get daemonset cilium -n kube-system \
    -o jsonpath='{.spec.template.spec.containers[0].image}' | sed -E 's/.*:v([0-9.]+).*/\1/')
fi

if [[ -z "$installed_cilium" ]]; then
  info "Installation de Cilium ${CILIUM_VERSION} avec Hubble…"
  cilium install --version "$CILIUM_VERSION" "${CILIUM_FLAGS[@]}"
elif [[ "$installed_cilium" != "$CILIUM_VERSION" ]] \
  || ! kubectl get deployment hubble-ui -n kube-system >/dev/null 2>&1; then
  info "Mise à jour de Cilium ${installed_cilium} vers ${CILIUM_VERSION} avec Hubble…"
  cilium upgrade --version "$CILIUM_VERSION" "${CILIUM_FLAGS[@]}"
else
  ok "Cilium ${CILIUM_VERSION} et Hubble déjà installés."
fi

info "Attente de Cilium et Hubble (2 à 5 minutes)…"
cilium status --wait --wait-duration 10m >/dev/null \
  || die "Cilium n'est pas prêt. Diagnostic : cilium status ; kubectl get pods -n kube-system"
ok "Cilium ${CILIUM_VERSION} prêt (Hubble, Relay et UI compris)."

kubectl wait --for=condition=Ready node --all --timeout=120s >/dev/null
ok "Nœud Ready."

# --- 6. Components shipped with k3s -------------------------------------------------
# Traefik is installed by a Helm job after startup: its Deployment may take a
# minute to appear.

for component in coredns local-path-provisioner metrics-server traefik; do
  info "Attente de ${component}…"
  for _ in $(seq 1 90); do
    kubectl get deployment "$component" -n kube-system >/dev/null 2>&1 && break
    sleep 2
  done
  kubectl rollout status deployment "$component" -n kube-system --timeout=180s >/dev/null \
    || die "${component} n'a pas démarré. Diagnostic : kubectl get pods -n kube-system"
  ok "${component} prêt."
done

# --- 7. Hubble UI Ingress -----------------------------------------------------------

kubectl apply -f "$(dirname "$0")/hubble-ui-ingress.yaml" >/dev/null
ok "Hubble UI exposée par Traefik sur http://hubble.localhost"

# --- 8. Training namespaces ---------------------------------------------------------

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
