# Atelier 4 — Ressources, QoS, stockage

## Objectif

Dimensionner `api-paiements`, lire sa classe de QoS, et donner au cache de sessions
`cache-sessions` un stockage qui survit au pod.

**Durée** : 45 min

| Partie | Durée |
|---|---|
| A — Dimensionner `api-paiements` | 20 min |
| B — Lire les classes de QoS | 5 min |
| C — Un stockage qui survit au pod | 20 min |

## Prérequis

- Atelier 3 terminé : `../atelier-3-sondes/verifier.sh` entièrement vert.
  Sinon, rattrapez l'état de fin de l'atelier 3 :
  ```bash
  kubectl apply -f depart/00-socle.yaml
  ```
- Vous êtes dans le dossier de l'atelier :
  ```bash
  cd atelier-4-ressources-stockage
  ```

## Mise en place

```bash
export NS=bdc
kubectl config set-context --current --namespace=$NS
```

Gardez un second terminal ouvert :

```bash
kubectl get pods -w
```

> 🎯 **Cet atelier contient 3 défauts**, répartis dans les fichiers de `depart/`.
> Seul `02-qos-trio.yaml` est correct : il sert à l'observation.
>
> Mode **boîte noire** (recommandé) ou **relecture**, au choix.

---

## Partie A — Dimensionner `api-paiements` (20 min)

`01-api-paiements-ressources.yaml` ajoute des ressources au Deployment de l'atelier 3.
Nouvelle réalité de l'appli : elle garde **150 Mo de cache en mémoire** dès son
démarrage (`BALLON_MEMOIRE_MO=150`).

| Champ | Utilisé par | Effet |
|---|---|---|
| `requests` | le **scheduler** | réservation : le pod n'est placé que sur un nœud qui a cette capacité **libre** |
| `limits.cpu` | le noyau | au-delà, le conteneur est ralenti |
| `limits.memory` | le noyau | au-delà, le conteneur est **tué** |

### Étape 1 — Appliquer et observer

```bash
kubectl apply -f depart/01-api-paiements-ressources.yaml
```

Sortie attendue :

```
deployment.apps/api-paiements configured
```

Observez le second terminal pendant 1 à 2 minutes. Le nouveau pod démarre-t-il ? Les
anciens sont-ils touchés ?

### Étape 2 — Diagnostiquer et corriger

Vos outils :

```bash
kubectl describe pod <nouveau-pod>                       # Events ; Last State
kubectl get events --sort-by=.lastTimestamp | tail -20
kubectl describe node | grep -A 12 'Allocated resources' # réservations sur le nœud
kubectl get node -o jsonpath='{.items[0].status.allocatable}{"\n"}'   # capacité du nœud
kubectl logs <nouveau-pod> --previous
kubectl top pod                                          # consommation réelle
```

Contraintes :

- **ne retirez pas** `BALLON_MEMOIRE_MO` : on dimensionne l'appli, on ne la change pas ;
- la classe de QoS de `api-paiements` doit rester **Burstable** (partie B).

Corrigez votre copie de `depart/01-api-paiements-ressources.yaml` et réappliquez
jusqu'à obtenir, rollout terminé (environ 2 min 30, comme à l'atelier 3) :

```bash
kubectl rollout status deployment/api-paiements
```

```
deployment "api-paiements" successfully rolled out
```

### Étape 3 — Réservé contre consommé

```bash
kubectl top pod -l app.kubernetes.io/name=api-paiements
kubectl get deploy api-paiements -o jsonpath='{.spec.template.spec.containers[0].resources}{"\n"}'
kubectl describe node | grep -A 12 'Allocated resources'
```

Sortie attendue (les valeurs varient) :

```
NAME                             CPU(cores)   MEMORY(bytes)
api-paiements-6c4d8b7f9-4kq2x    1m           158Mi
api-paiements-6c4d8b7f9-8zt5n    1m           157Mi
api-paiements-6c4d8b7f9-w9hpl    1m           158Mi
```

Répondez :

1. Combien de CPU vos pods **consomment**-ils ? Combien en **réservent**-ils ?
2. Le scheduler a-t-il regardé la consommation réelle pour refuser `cpu: "64"` ?
3. Sur votre nœud, combien de pods réservant 1 cœur pourriez-vous placer, même s'ils
   ne font rien ?

> 💡 **Le scheduler compte les requests, pas la consommation.** Des requests trop
> hautes gaspillent le cluster ; trop basses, elles entassent des pods qui se
> disputeront le nœud.

---

## Partie B — Lire les classes de QoS (5 min)

```bash
kubectl apply -f depart/02-qos-trio.yaml
kubectl get pod -o custom-columns=NOM:.metadata.name,QOS:.status.qosClass
```

Sortie attendue (les noms varient) :

```
NOM                               QOS
api-paiements-6c4d8b7f9-4kq2x     Burstable
api-paiements-6c4d8b7f9-8zt5n     Burstable
api-paiements-6c4d8b7f9-w9hpl     Burstable
portail-client-5b7d9c8f4-hx2lq    BestEffort
portail-client-5b7d9c8f4-p8wzt    BestEffort
qos-besteffort                    BestEffort
qos-burstable                     Burstable
qos-guaranteed                    Guaranteed
```

Ouvrez `02-qos-trio.yaml` et retrouvez la règle :

| Classe | Règle | Si le nœud manque de mémoire |
|---|---|---|
| BestEffort | ni requests ni limits | évincé **en premier** |
| Burstable | des requests, limits absentes ou plus hautes | ensuite |
| Guaranteed | requests = limits, CPU et mémoire | évincé **en dernier** |

Question : `portail-client` est **BestEffort**. Est-ce raisonnable pour le portail de
la banque ?

---

## Partie C — Un stockage qui survit au pod (20 min)

`cache-sessions` garde les sessions des clients dans `/donnees`. Il lui faut un volume
qui survive au pod.

| Objet | Rôle |
|---|---|
| **PersistentVolumeClaim** (PVC) | la demande : « 1 Gi, en lecture-écriture » |
| **StorageClass** | la méthode : comment créer le volume (`kubectl get storageclass`) |
| **PersistentVolume** (PV) | le volume réel, créé par la StorageClass et lié au PVC |

### Étape 4 — Appliquer, diagnostiquer, corriger

```bash
kubectl apply -f depart/03-cache-sessions-pvc.yaml -f depart/04-cache-sessions.yaml
kubectl get pvc,pod -l app.kubernetes.io/name=cache-sessions
```

Vos outils :

```bash
kubectl describe pvc cache-sessions
kubectl describe pod -l app.kubernetes.io/name=cache-sessions
kubectl get storageclass
```

Corrigez jusqu'à obtenir (les noms varient) :

```
NAME                                   STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
persistentvolumeclaim/cache-sessions   Bound    pvc-3f2a9c1e-8b4d-4e7a-9f1c-2d6b5a8e0c47   1Gi        RWO            local-path     40s

NAME                                  READY   STATUS    RESTARTS   AGE
pod/cache-sessions-7d9f8c6b5-rx4tm    1/1     Running   0          40s
```

> ⚠️ Certains champs d'un PVC sont **immuables** : lisez attentivement le message si
> `kubectl apply` refuse votre correction.

### Étape 5 — Le fichier survit-il au pod ?

```bash
kubectl exec deploy/cache-sessions -- sh -c 'echo "session client 4521" > /donnees/session.txt'
kubectl delete pod -l app.kubernetes.io/name=cache-sessions
kubectl rollout status deployment/cache-sessions
kubectl exec deploy/cache-sessions -- cat /donnees/session.txt
```

Sortie attendue :

```
pod "cache-sessions-7d9f8c6b5-rx4tm" deleted
deployment "cache-sessions" successfully rolled out
session client 4521
```

Le pod est nouveau, le fichier est toujours là : il vit dans le volume, pas dans le
conteneur.

### Critères de réussite — avant l'étape 6

```bash
./verifier.sh
```

Le script contrôle :

1. `api-paiements` : 3 pods `Ready`, rollout terminé.
2. Le cache mémoire est conservé (`BALLON_MEMOIRE_MO=150`).
3. Aucun redémarrage ni `OOMKilled` ; QoS **Burstable**.
4. Les trois pods du trio ont la classe de QoS attendue.
5. Le PVC `cache-sessions` est `Bound`.
6. `/donnees/session.txt` existe et a survécu à la recréation du pod.

Sortie attendue :

```
✅ Deployment api-paiements : 3/3 pods Ready, rollout terminé
✅ Cache mémoire conservé (BALLON_MEMOIRE_MO=150)
✅ Pods api-paiements : 0 restart, aucun OOMKilled
✅ Pods api-paiements : QoS Burstable
✅ Pod qos-besteffort : QoS BestEffort
✅ Pod qos-burstable : QoS Burstable
✅ Pod qos-guaranteed : QoS Guaranteed
✅ PVC cache-sessions : Bound (local-path)
✅ Fichier /donnees/session.txt présent et antérieur au pod actuel : il a survécu à la recréation du pod

🎉 Atelier 4 réussi. Passez à l'étape 6 (elle supprime le stockage, c'est voulu).
```

### Étape 6 — Que devient le volume quand on supprime le PVC ?

> Faites le **bonus** avant cette étape si vous le souhaitez : il a besoin du volume.

```bash
kubectl get pv
kubectl delete deployment cache-sessions
kubectl delete pvc cache-sessions
kubectl get pv
```

Sortie attendue (avant, puis après) :

```
NAME                                       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM                STORAGECLASS   ...
pvc-3f2a9c1e-8b4d-4e7a-9f1c-2d6b5a8e0c47   1Gi        RWO            Delete           Bound    bdc/cache-sessions   local-path     ...
deployment.apps "cache-sessions" deleted
persistentvolumeclaim "cache-sessions" deleted
No resources found
```

`RECLAIM POLICY: Delete` : supprimer le PVC a **détruit le volume et ses données**.
Avec `Retain`, le volume aurait survécu (état `Released`), à récupérer à la main.

Questions :

1. Pourquoi a-t-on supprimé le Deployment **avant** le PVC ? (Essayez l'inverse lors
   d'une prochaine reprise : `kubectl get pvc` pendant la suppression.)
2. Pour les données de paiement, préféreriez-vous `Delete` ou `Retain` ?

## Bonus — Pourquoi `strategy: Recreate` ?

À faire **avant l'étape 6** (ou après avoir réappliqué `03` et `04` corrigés).

```bash
kubectl scale deployment/cache-sessions --replicas=2
kubectl get pods -l app.kubernetes.io/name=cache-sessions -o wide
```

Les deux pods sont `Running`, sur le même nœud, **avec le même volume** `ReadWriteOnce`.
Écrivez depuis l'un, lisez depuis l'autre :

```bash
kubectl exec <pod-1> -- sh -c 'echo "écrit par pod-1" >> /donnees/journal.txt'
kubectl exec <pod-2> -- cat /donnees/journal.txt
```

`ReadWriteOnce` veut dire « **un seul nœud** », pas « un seul pod » : sur un nœud
unique, rien n'empêche deux écrivains concurrents de corrompre les données. Un
`RollingUpdate` crée exactement cette situation à chaque mise à jour (nouveau pod
démarré avant l'arrêt de l'ancien). `Recreate` l'évite : l'ancien pod s'arrête d'abord.

Revenez à un réplica : `kubectl scale deployment/cache-sessions --replicas=1`.

## En cas de besoin

- Repartir de zéro : `./reset.sh` (revient à l'état de fin de l'atelier 3 ; supprime
  les données de `cache-sessions`)
- Rattraper le groupe : `kubectl apply -f depart/00-socle.yaml -f solution/`
  (à demander au formateur)
