# Atelier 1 — Deployment, Service, réconciliation

## Objectif

Déployer `api-paiements` avec sa configuration, l'exposer à l'intérieur du cluster,
et constater que Kubernetes ramène toujours le réel vers ce qui est déclaré.

**Durée** : 1 h 30

| Partie | Durée |
|---|---|
| A — La boucle de correction | 10 min |
| B — Corriger et déployer `api-paiements` | 40 min |
| C — Réconciliation et rollout | 30 min |
| Bilan | 10 min |

## Prérequis

- k3s installé sur votre poste, `commun/verifier-poste.sh` entièrement vert.
- Namespace `bdc` vide : `kubectl get all -n bdc` répond `No resources found in bdc namespace.`
- Vous êtes dans le dossier de l'atelier :
  ```bash
  cd atelier-1-deployment-service
  ```

> ⚠️ Vous êtes administrateur de votre cluster : rien ne vous empêche de tout casser.
> Ne modifiez et ne supprimez **jamais** rien dans le namespace `kube-system`.

## Mise en place

```bash
export NS=bdc
kubectl config set-context --current --namespace=$NS
```

Sortie attendue :

```
Context "default" modified.
```

À partir d'ici, toutes les commandes s'exécutent dans `bdc` sans préciser `-n`.

---

## Partie A — La boucle de correction (10 min)

Tout au long de la formation, vous corrigerez des manifests défectueux avec la même
boucle de quatre commandes :

```
kubectl apply --dry-run=server -f <fichier>   → l'API valide-t-elle ?
kubectl diff -f <fichier>                     → qu'est-ce que ma correction change ?
kubectl explain <ressource.chemin>            → nom exact et type du champ
kubectl apply -f <fichier>                    → appliquer
```

Essayez `kubectl explain` dès maintenant :

```bash
kubectl explain deployment.spec.template.spec.containers.envFrom
```

Sortie attendue (début) :

```
GROUP:      apps
KIND:       Deployment
VERSION:    v1

FIELD: envFrom <[]EnvFromSource>
...
```

Les défauts que vous rencontrerez se classent en trois niveaux :

| Niveau | Symptôme | Commande qui le révèle |
|---|---|---|
| 1 — l'API refuse | rien n'est créé | `kubectl apply --dry-run=server -f` |
| 2 — l'objet n'aboutit pas | `Pending`, `ImagePullBackOff`, 0 endpoint | `kubectl describe`, `kubectl get events` |
| 3 — ça tourne, mais c'est faux | `RESTARTS`, `CrashLoopBackOff`, timeouts | `kubectl logs --previous`, test fonctionnel |

---

## Partie B — Corriger et déployer `api-paiements` (40 min)

Le dossier `depart/` contient trois manifests :

| Fichier | Contenu |
|---|---|
| `01-configmap.yaml` | ConfigMap `api-paiements-config` (`DEVISE`, `NIVEAU_JOURNAL`) |
| `02-deployment.yaml` | Deployment `api-paiements`, 3 réplicas, image `1.0` |
| `03-service.yaml` | Service `api-paiements`, ClusterIP, port 80 → 8080 |

> 🎯 **Cet atelier contient 4 défauts.** Ils peuvent se trouver dans les fichiers
> **ou dans les commandes de cet énoncé**. Ils ne sont pas tous du même niveau.

Choisissez votre mode :

- **Boîte noire** (recommandé) : appliquez, observez, diagnostiquez avec `kubectl`.
  N'ouvrez un fichier que lorsque vous savez ce que vous y cherchez.
- **Relecture** : lisez d'abord les fichiers, puis appliquez. Certains défauts ne se
  voient pas à la lecture : vous devrez quand même diagnostiquer.

### Étape 1 — Créer la ConfigMap

```bash
kubectl apply -f depart/01-configmap.yaml
```

Sortie attendue :

```
configmap/api-paiements-config created
```

### Étape 2 — Créer le Secret (commande impérative imposée)

Le mot de passe de la base de données ne doit pas se trouver dans un fichier versionné.
Créez le Secret directement :

```bash
kubectl create secret generic api-paiements-secret \
  --from-literal=DB_MOT_DE_PASSE=formation-bdc
```

Sortie attendue :

```
secret/api-paiements-secret created
```

> ⚠️ **À savoir pour la production** : un Secret n'est **pas chiffré**. Son contenu est
> seulement encodé en base64 — essayez :
> `kubectl get secret api-paiements-secret -o jsonpath='{.data}'`, puis décodez la
> valeur avec `base64 -d`. Toute personne qui peut lire les Secrets du namespace lit
> le mot de passe.

### Étape 3 — Faire accepter le Deployment par l'API

```bash
kubectl apply --dry-run=server -f depart/02-deployment.yaml
```

Corrigez le fichier jusqu'à obtenir :

```
deployment.apps/api-paiements created (server dry run)
```

Lisez attentivement chaque message d'erreur : il indique le **chemin** du champ en
cause (`spec.template...`). `kubectl explain` vous donne la structure attendue.

### Étape 4 — Déployer et obtenir 3 pods sains

```bash
kubectl apply -f depart/02-deployment.yaml
kubectl get pods -w        # Ctrl+C pour arrêter
```

Sortie attendue une fois **tous** les défauts concernés corrigés :

```
NAME                             READY   STATUS    RESTARTS   AGE
api-paiements-6d8f7c9b5d-4kx2p   1/1     Running   0          40s
api-paiements-6d8f7c9b5d-9wq7m   1/1     Running   0          40s
api-paiements-6d8f7c9b5d-tz8hn   1/1     Running   0          40s
```

Si ce n'est pas le cas, faites raconter leur histoire aux pods :

```bash
kubectl describe pod <nom-du-pod>      # section Events en bas
kubectl logs <nom-du-pod>              # journaux du conteneur actuel
kubectl logs <nom-du-pod> --previous   # journaux du conteneur précédent (après un crash)
kubectl get events --sort-by=.lastTimestamp
```

### Étape 5 — Exposer avec le Service

```bash
kubectl apply -f depart/03-service.yaml
kubectl get endpointslices -l kubernetes.io/service-name=api-paiements
```

Sortie attendue une fois corrigé (les adresses varient) :

```
NAME                  ADDRESSTYPE   PORTS   ENDPOINTS                          AGE
api-paiements-7xq4d   IPv4          8080    10.42.0.12,10.42.0.13,10.42.0.14   1m
```

> ℹ️ Les EndpointSlices listent les pods derrière un Service. L'ancien objet
> `Endpoints` (`kubectl get endpoints`) existe encore mais est **déprécié** depuis
> Kubernetes 1.33.

Pour comprendre ce que le Service sélectionne :

```bash
kubectl describe svc api-paiements
kubectl get pods --show-labels
```

---

## Partie C — Réconciliation et rollout (30 min)

Prérequis : 3 pods `Running`, Service avec 3 endpoints. Gardez un second terminal ouvert
avec `kubectl get pods -w` pendant toute cette partie.

### Étape 6 — Supprimer un pod

```bash
kubectl delete pod <un-des-pods>
```

Sortie attendue :

```
pod "api-paiements-6d8f7c9b5d-4kx2p" deleted
```

Dans le second terminal : un nouveau pod apparaît en quelques secondes. Le ReplicaSet
constate 2 pods au lieu de 3 et en recrée un.

### Étape 7 — Le fichier fait foi (commande impérative imposée)

```bash
kubectl scale deployment/api-paiements --replicas=5
kubectl get pods
```

Sortie attendue : `deployment.apps/api-paiements scaled`, puis 5 pods.

Réappliquez maintenant **votre** fichier corrigé :

```bash
kubectl apply -f depart/02-deployment.yaml
kubectl get pods
```

Sortie attendue : `deployment.apps/api-paiements configured`, puis retour à 3 pods
(2 en `Terminating`). Le fichier dit `replicas: 3` : c'est lui qui a le dernier mot.

### Étape 8 — Tout tient sur les labels

Retirez un pod du troupeau en changeant son label :

```bash
kubectl label pod <un-des-pods> app.kubernetes.io/name=quarantaine --overwrite
kubectl get pods -L app.kubernetes.io/name
```

Sortie attendue (les noms varient) :

```
NAME                             READY   STATUS    RESTARTS   AGE   NAME
api-paiements-6d8f7c9b5d-9wq7m   1/1     Running   0          8m    quarantaine
api-paiements-6d8f7c9b5d-m2v6c   1/1     Running   0          5s    api-paiements
api-paiements-6d8f7c9b5d-tz8hn   1/1     Running   0          8m    api-paiements
api-paiements-6d8f7c9b5d-xk4rb   1/1     Running   0          3m    api-paiements
```

Le ReplicaSet ne « voit » plus le pod relabellisé : il en a créé un nouveau. Vérifiez que
le Service l'a aussi abandonné :

```bash
kubectl get pod <pod-en-quarantaine> -o wide          # notez son IP
kubectl get endpointslices -l kubernetes.io/service-name=api-paiements
```

L'IP du pod en quarantaine n'apparaît plus. Le pod tourne toujours, mais plus personne
ne le gère : c'est utile pour garder un pod défaillant à des fins d'analyse. Supprimez-le :

```bash
kubectl delete pod <pod-en-quarantaine>
```

### Étape 9 — Rollout et retour arrière (commandes impératives imposées)

Passez à la version `1.1` :

```bash
kubectl set image deployment/api-paiements app=ghcr.io/gologic/bdc-formation/app:1.1
kubectl rollout status deployment/api-paiements
```

Sortie attendue :

```
deployment.apps/api-paiements image updated
Waiting for deployment "api-paiements" rollout to finish: 1 out of 3 new replicas have been updated...
...
deployment "api-paiements" successfully rolled out
```

Consultez l'historique, puis revenez en arrière :

```bash
kubectl rollout history deployment/api-paiements
kubectl rollout undo deployment/api-paiements
kubectl rollout status deployment/api-paiements
```

Sortie attendue : une liste de révisions (`REVISION  CHANGE-CAUSE`, au moins deux
lignes), puis `deployment.apps/api-paiements rolled back` et
`deployment "api-paiements" successfully rolled out`.

> 💡 `set image` a créé un écart entre le cluster (`1.1`) et votre fichier (`1.0`). Le
> `rollout undo` a refermé cet écart. Sans lui, le prochain `kubectl apply` l'aurait
> fait — c'est pourquoi, en production, on modifie le fichier plutôt que le cluster.

### Étape 10 — Tester depuis l'intérieur du cluster (commande impérative imposée)

```bash
kubectl run test --rm -it --restart=Never \
  --image=ghcr.io/gologic/bdc-formation/app:1.0 \
  --command -- wget -qO- http://api-paiements
```

Sortie attendue (le nom du pod varie) :

```
{"appli":"api-paiements","version":"1.0","pod":"api-paiements-6d8f7c9b5d-tz8hn","namespace":"bdc"}
pod "test" deleted
```

Relancez la commande plusieurs fois : le champ `pod` change, le Service répartit les
requêtes entre les trois pods.

---

## Critères de réussite

```bash
./verifier.sh
```

Le script contrôle :

1. Le Deployment `api-paiements` a 3 pods `Ready`.
2. Aucun de ces pods n'a redémarré depuis le dernier rollout.
3. Le Service `api-paiements` a 3 endpoints prêts.
4. `http://api-paiements/` répond avec la version `1.0`.
5. Le Secret `api-paiements-secret` contient la clé `BD_MOT_DE_PASSE`.

Sortie attendue :

```
✅ Deployment api-paiements : 3/3 pods Ready
✅ Pods api-paiements : 3 pods, 0 restart depuis le dernier rollout
✅ Service api-paiements : 3 endpoints prêts
✅ http://api-paiements/ répond avec la version 1.0
✅ Secret api-paiements-secret : contient BD_MOT_DE_PASSE

🎉 Atelier 1 réussi.
```

## Bonus

1. Ajoutez une stratégie de rollout explicite au Deployment :
   ```yaml
   strategy:
     type: RollingUpdate
     rollingUpdate:
       maxUnavailable: 0
       maxSurge: 1
   ```
   Refaites l'étape 9 et comparez le déroulement dans `kubectl get pods -w`.
2. Pendant un rollout, observez les endpoints entrer et sortir du Service :
   ```bash
   kubectl get endpointslices -l kubernetes.io/service-name=api-paiements -w
   ```

## En cas de besoin

- Repartir de zéro : `./reset.sh`
- Rattraper le groupe : `kubectl apply -f solution/` (à demander au formateur)
