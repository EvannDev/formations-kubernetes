# Glossaire — Formation 1

Une ligne par terme, dans l'ordre où ils apparaissent pendant la formation.

## Mise en place

| Terme | Définition |
|---|---|
| **Conteneur** | Processus isolé qui embarque son application et ses dépendances ; démarre en quelques secondes. |
| **Image** | Gabarit en lecture seule d'un conteneur (système de fichiers + commande de démarrage). |
| **Registre** | Serveur qui stocke et distribue les images (ici `ghcr.io`). |
| **Tag** | Étiquette de version d'une image (`app:1.0`). Un tag inexistant empêche le démarrage. |
| **Cluster** | Ensemble de machines gérées par Kubernetes comme un tout. |
| **Nœud (node)** | Machine du cluster qui exécute les conteneurs. Votre poste est un cluster d'un seul nœud. |
| **k3s** | Distribution Kubernetes légère, complète et certifiée, utilisée pour la formation. |
| **CNI** | Interface standard des plugins qui donnent une adresse IP et un réseau aux pods. |
| **Cilium** | Plugin CNI utilisé sur vos postes ; il gère aussi les Services (à la place de kube-proxy). |
| **API server** | Point d'entrée unique du cluster : tout passe par lui, y compris `kubectl`. |
| **kubectl** | Outil en ligne de commande qui dialogue avec l'API server. |
| **kubeconfig** | Fichier (`~/.kube/config`) qui dit à `kubectl` quel cluster joindre et avec quelle identité. |
| **Contexte** | Combinaison cluster + utilisateur + namespace par défaut, dans le kubeconfig. |
| **Namespace** | Espace de noms qui isole des groupes d'objets dans un cluster (`bdc`, `kube-system`). |
| **`kube-system`** | Namespace des composants internes du cluster. On n'y touche pas. |

## Atelier 1 — Deployment, Service, réconciliation

| Terme | Définition |
|---|---|
| **Manifest** | Fichier YAML qui décrit un objet Kubernetes dans l'état voulu. |
| **YAML** | Format texte des manifests ; l'indentation (espaces, jamais de tabulations) définit la structure. |
| **Déclaratif** | On décrit l'état voulu (`kubectl apply -f`) ; Kubernetes se charge d'y arriver. |
| **Impératif** | On donne un ordre ponctuel (`kubectl scale`, `kubectl set image`) ; rien ne le mémorise dans un fichier. |
| **Dry-run** | Simulation : l'API valide la demande sans rien créer (`--dry-run=server`). |
| **Pod** | Plus petite unité déployable : un ou plusieurs conteneurs qui partagent réseau et stockage. |
| **Label** | Paire clé/valeur attachée à un objet (`app.kubernetes.io/name: api-paiements`). |
| **Selector** | Requête sur les labels ; c'est ainsi qu'un objet en retrouve d'autres. |
| **Deployment** | Objet qui maintient un nombre de pods identiques et gère leurs mises à jour. |
| **ReplicaSet** | Objet créé par le Deployment, qui maintient le nombre exact de pods d'une version donnée. |
| **Réplica** | Un exemplaire du pod ; `replicas: 3` = trois pods identiques. |
| **ConfigMap** | Objet qui stocke de la configuration non sensible, injectée dans les pods. |
| **Secret** | Objet destiné aux données sensibles. Encodé en base64, **pas chiffré** par défaut. |
| **base64** | Encodage réversible par n'importe qui ; ce n'est pas du chiffrement. |
| **`envFrom`** | Injecte toutes les clés d'une ConfigMap ou d'un Secret comme variables d'environnement. |
| **`CrashLoopBackOff`** | Le conteneur plante à répétition ; Kubernetes espace de plus en plus les redémarrages. |
| **Back-off** | Délai croissant entre deux tentatives (10 s, 20 s, 40 s… jusqu'à 5 min). |
| **Event** | Message horodaté émis par le cluster à propos d'un objet (`kubectl get events`). |
| **Service** | Adresse et nom DNS stables devant un groupe de pods choisis par selector. |
| **ClusterIP** | Type de Service par défaut : joignable uniquement depuis l'intérieur du cluster. |
| **Endpoint** | Adresse d'un pod prêt derrière un Service. |
| **EndpointSlice** | Objet qui liste les endpoints d'un Service (`kubectl get endpointslices`). |
| **Endpoints** | Ancien objet équivalent aux EndpointSlices, déprécié depuis Kubernetes 1.33. |
| **Réconciliation** | Boucle permanente qui ramène le réel vers l'état déclaré. |
| **Rollout** | Remplacement progressif des pods par une nouvelle version. |
| **Révision** | Version numérotée d'un Deployment, conservée pour le retour arrière (`rollout undo`). |
| **Immuable** | Champ qu'on ne peut plus modifier après la création (ex. selector d'un Deployment). |

## Atelier 2 — Exposition et DNS

| Terme | Définition |
|---|---|
| **port-forward** | Tunnel temporaire entre un port de votre poste et un pod ou un Service (`kubectl port-forward`). |
| **`port` / `targetPort`** | Port exposé par le Service / port sur lequel le conteneur écoute réellement. |
| **Port nommé** | Port désigné par un nom (`http`) plutôt que par un numéro. |
| **DNS du cluster (CoreDNS)** | Service qui résout les noms de Services en adresses IP. |
| **FQDN** | Nom complet d'un Service : `<service>.<namespace>.svc.cluster.local`. |
| **`/etc/resolv.conf`** | Fichier du pod qui indique le serveur DNS et les suffixes de recherche. |
| **NXDOMAIN** | Réponse DNS « ce nom n'existe pas ». |
| **Ingress** | Règles de routage HTTP de l'extérieur vers des Services (par hôte ou chemin). |
| **Contrôleur Ingress** | Logiciel qui applique les règles d'Ingress ; ici Traefik. |
| **IngressClass** | Désigne le contrôleur Ingress chargé d'un Ingress (`traefik`). |
| **Traefik** | Contrôleur Ingress fourni par k3s, à l'écoute sur les ports 80 et 443 du poste. |
| **NodePort** | Service exposé sur un port fixe de chaque nœud. À éviter en production. |
| **LoadBalancer** | Service exposé par un répartiteur de charge externe ; sur un cloud, une ressource facturée. |
| **ServiceLB** | Implémentation locale de `LoadBalancer` fournie par k3s ; non représentative d'un cloud. |
| **NetworkPolicy** | Règles de pare-feu entre pods (vues en F2). |

## Atelier 3 — Sondes

| Terme | Définition |
|---|---|
| **Sonde (probe)** | Test périodique que le kubelet fait sur un conteneur. |
| **kubelet** | Agent sur chaque nœud qui démarre les conteneurs et exécute les sondes. |
| **Liveness** | « Le conteneur est-il bloqué ? » — en cas d'échec, il est **redémarré**. |
| **Readiness** | « Peut-il recevoir du trafic ? » — en cas d'échec, il est **retiré du Service**. |
| **Startup probe** | « A-t-il fini de démarrer ? » — suspend les autres sondes pendant le démarrage. |
| **`initialDelaySeconds`** | Attente avant le premier test d'une sonde. |
| **`periodSeconds`** | Intervalle entre deux tests. |
| **`failureThreshold`** | Nombre d'échecs consécutifs avant sanction. |

## Atelier 4 — Ressources, QoS, stockage

| Terme | Définition |
|---|---|
| **Requests** | Ressources réservées pour un conteneur ; ce que le scheduler compte. |
| **Limits** | Plafond de consommation : au-delà, CPU ralenti ou conteneur tué (mémoire). |
| **Scheduler** | Composant qui choisit le nœud de chaque pod en fonction des requests. |
| **`Pending`** | Pod accepté, mais pas encore placé sur un nœud (ou en attente d'un volume). |
| **`OOMKilled`** | Conteneur tué pour avoir dépassé sa limite de mémoire. |
| **metrics-server** | Collecte la consommation réelle CPU/mémoire (`kubectl top`). |
| **QoS** | Classe de priorité d'un pod, déduite de ses requests et limits. |
| **BestEffort** | Ni requests ni limits : premier pod évincé en cas de manque de ressources. |
| **Burstable** | Requests définies, inférieures aux limits (ou limits absentes). |
| **Guaranteed** | Requests = limits pour CPU et mémoire : dernier pod évincé. |
| **LimitRange** | Objet qui impose des requests/limits par défaut dans un namespace (absent ici, volontairement). |
| **PersistentVolumeClaim (PVC)** | Demande de stockage faite par une application. |
| **PersistentVolume (PV)** | Volume réel attribué à un PVC. |
| **StorageClass** | Type de stockage et méthode de création des volumes (`local-path` sur k3s). |
| **RWO (ReadWriteOnce)** | Volume monté en écriture par **un seul nœud** à la fois (pas un seul pod). |
| **`WaitForFirstConsumer`** | Le volume n'est créé qu'au moment où un pod l'utilise. |
| **`reclaimPolicy`** | Sort du volume quand le PVC est supprimé : `Delete` (détruit) ou `Retain` (conservé). |
| **Stratégie `Recreate`** | Arrête tous les anciens pods avant de démarrer les nouveaux. |
| **Stratégie `RollingUpdate`** | Remplace les pods progressivement, anciens et nouveaux coexistent. |

## Atelier 5 — Diagnostic

| Terme | Définition |
|---|---|
| **`ImagePullBackOff`** | Kubernetes n'arrive pas à télécharger l'image (tag ou nom erroné, accès refusé). |
| **`CreateContainerConfigError`** | Le conteneur ne peut être configuré (ex. ConfigMap ou Secret introuvable). |
| **`nodeSelector`** | Contraint un pod aux nœuds portant certains labels. |

## Démos

| Terme | Définition |
|---|---|
| **HPA (HorizontalPodAutoscaler)** | Ajuste automatiquement le nombre de réplicas selon la consommation. |
