#!/usr/bin/env bash
# Désinstalle k3s (et Cilium) du poste et remet l'environnement de l'utilisateur en état.
# ⚠️ Supprime le cluster ET toutes ses données (volumes local-path compris).
#
# Usage : ./desinstaller-poste.sh [--oui]
#   --oui   ne pas demander de confirmation
set -euo pipefail

KUBECONFIG_UTILISATEUR="${HOME}/.kube/config"
MARQUEUR_RC="# formation-bdc : kubeconfig k3s"

info() { echo "▶ $*"; }
ok()   { echo "✅ $*"; }

if [[ "${1:-}" != "--oui" ]]; then
  echo "Cette opération supprime k3s, le cluster de formation et toutes ses données."
  read -r -p "Continuer ? Tapez « oui » : " reponse
  [[ "$reponse" == "oui" ]] || { echo "Annulé."; exit 1; }
fi

# --- 1. k3s -------------------------------------------------------------------

if [[ -x /usr/local/bin/k3s-uninstall.sh ]]; then
  info "Désinstallation de k3s…"
  sudo /usr/local/bin/k3s-uninstall.sh
  ok "k3s désinstallé."
else
  ok "k3s n'est pas installé."
fi

# Restes de Cilium hors des dossiers de k3s : configuration et plugin CNI,
# interfaces réseau. Les programmes eBPF disparaissent au redémarrage.
sudo rm -f /etc/cni/net.d/05-cilium.conflist /opt/cni/bin/cilium-cni
for interface in cilium_host cilium_net cilium_vxlan; do
  if ip link show "$interface" >/dev/null 2>&1; then
    sudo ip link delete "$interface"
  fi
done
ok "Restes de Cilium supprimés (un redémarrage du poste termine le nettoyage)."

if [[ -f /usr/local/bin/cilium ]]; then
  sudo rm -f /usr/local/bin/cilium
  ok "CLI cilium supprimé."
fi

# --- 2. Kubeconfig ------------------------------------------------------------
# Le kubeconfig de la formation pointe vers https://127.0.0.1:6443, qui n'existe
# plus. On restaure la sauvegarde la plus récente faite par installer-poste.sh.

if [[ -f "$KUBECONFIG_UTILISATEUR" ]] && grep -q 'server: https://127.0.0.1:6443' "$KUBECONFIG_UTILISATEUR"; then
  sauvegarde=$(ls -1t "${KUBECONFIG_UTILISATEUR}".avant-formation-* 2>/dev/null | head -1 || true)
  if [[ -n "$sauvegarde" ]]; then
    mv "$sauvegarde" "$KUBECONFIG_UTILISATEUR"
    ok "Kubeconfig précédent restauré depuis ${sauvegarde}."
  else
    rm -f "$KUBECONFIG_UTILISATEUR"
    ok "Kubeconfig de la formation supprimé."
  fi
fi

# --- 3. Lignes ajoutées aux fichiers du shell ---------------------------------

for rc in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
  if [[ -f "$rc" ]] && grep -qF "$MARQUEUR_RC" "$rc"; then
    # Supprime le marqueur et la ligne export qui le suit
    sed -i "/^${MARQUEUR_RC}\$/{N;d;}" "$rc"
    ok "KUBECONFIG retiré de ${rc}."
  fi
done

echo
ok "Poste nettoyé. Ouvrez un nouveau terminal."
