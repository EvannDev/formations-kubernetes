#!/usr/bin/env bash
# Uninstalls k3s (and Cilium) from the machine and restores the user's environment.
# ⚠️ Deletes the cluster AND all its data (local-path volumes included).
#
# Usage: ./desinstaller-poste.sh [--oui]
#   --oui   do not ask for confirmation
# Messages are in French: participants read them.
set -euo pipefail

USER_KUBECONFIG="${HOME}/.kube/config"
# Must match the marker written by installer-poste.sh
RC_MARKER="# formation-bdc : kubeconfig k3s"

info() { echo "▶ $*"; }
ok()   { echo "✅ $*"; }

if [[ "${1:-}" != "--oui" ]]; then
  echo "Cette opération supprime k3s, le cluster de formation et toutes ses données."
  read -r -p "Continuer ? Tapez « oui » : " answer
  [[ "$answer" == "oui" ]] || { echo "Annulé."; exit 1; }
fi

# --- 1. k3s -------------------------------------------------------------------------

if [[ -x /usr/local/bin/k3s-uninstall.sh ]]; then
  info "Désinstallation de k3s…"
  sudo /usr/local/bin/k3s-uninstall.sh
  ok "k3s désinstallé."
else
  ok "k3s n'est pas installé."
fi

# Cilium leftovers outside the k3s directories: CNI config and plugin,
# network interfaces. eBPF programs go away on reboot.
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

# --- 2. Kubeconfig ------------------------------------------------------------------
# The training kubeconfig points to https://127.0.0.1:6443, which no longer
# exists. Restore the most recent backup made by installer-poste.sh.

if [[ -f "$USER_KUBECONFIG" ]] && grep -q 'server: https://127.0.0.1:6443' "$USER_KUBECONFIG"; then
  backup=$(ls -1t "${USER_KUBECONFIG}".avant-formation-* 2>/dev/null | head -1 || true)
  if [[ -n "$backup" ]]; then
    mv "$backup" "$USER_KUBECONFIG"
    ok "Kubeconfig précédent restauré depuis ${backup}."
  else
    rm -f "$USER_KUBECONFIG"
    ok "Kubeconfig de la formation supprimé."
  fi
fi

# --- 3. Lines added to the shell rc files -------------------------------------------

for rc in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
  if [[ -f "$rc" ]] && grep -qF "$RC_MARKER" "$rc"; then
    # Delete the marker and the export line that follows it
    sed -i "/^${RC_MARKER}\$/{N;d;}" "$rc"
    ok "KUBECONFIG retiré de ${rc}."
  fi
done

echo
ok "Poste nettoyé. Ouvrez un nouveau terminal."
