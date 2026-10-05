# Atelier 3 — Liveness, readiness, startup

## Objectif

Calibrer les trois sondes de `api-paiements`, une appli lente à démarrer et
dépendante d'un service externe, puis constater ce qu'une liveness mal placée
provoque quand la dépendance tombe.

**Durée** : 45 min

| Partie | Durée |
|---|---|
| A — Les trois sondes en bref | 5 min |
| B — Faire démarrer l'appli lente | 25 min |
| C — Expérience : la dépendance tombe | 15 min |

## Prérequis

- Atelier 2 terminé : `../atelier-2-exposition-dns/verifier.sh` entièrement vert.
  Sinon, rattrapez l'état de fin de l'atelier 2 :
  ```bash
  kubectl apply -f depart/00-socle.yaml
  ```
- Vous êtes dans le dossier de l'atelier :
  ```bash
  cd atelier-3-sondes
  ```

## Mise en place

```bash
export NS=bdc
kubectl config set-context --current --namespace=$NS
```

Reprenez aussi l'entrée du cluster de l'atelier 2 (partie C) :

```bash
export ENTREE=http://localhost          # Linux natif
export ENTREE=http://localhost:8081     # WSL, avec le tunnel vers Traefik ouvert
```

Gardez un second terminal ouvert pendant tout l'atelier :

```bash
kubectl get pods -l app.kubernetes.io/name=api-paiements -w
```

---

## Partie A — Les trois sondes en bref (5 min)

Le kubelet interroge chaque conteneur à intervalles réguliers. Chaque sonde pose une
question différente et applique une sanction différente :

| Sonde | Question | En cas d'échec |
|---|---|---|
| **startup** | « As-tu fini de démarrer ? » | les deux autres sondes attendent ; au bout du budget, redémarrage |
| **liveness** | « Es-tu bloqué ? » | **redémarrage** du conteneur |
| **readiness** | « Peux-tu recevoir du trafic ? » | **retrait des endpoints** du Service, sans redémarrage |

Les réglages communs :

| Champ | Rôle | Défaut |
|---|---|---|
| `initialDelaySeconds` | attente avant le premier test | 0 |
| `periodSeconds` | intervalle entre deux tests | 10 |
| `failureThreshold` | échecs consécutifs avant sanction | 3 |

Délai avant sanction ≈ `periodSeconds × failureThreshold` (après `initialDelaySeconds`).

L'appli expose deux routes de santé :

- `/healthz` : « le processus fonctionne » ;
- `/readyz` : « je peux servir des requêtes » (dépend de la base et des services amont).

---

## Partie B — Faire démarrer l'appli lente (25 min)

`depart/01-api-paiements-sondes.yaml` est la nouvelle version du Deployment
`api-paiements`. L'appli y met **45 secondes à démarrer** (`DELAI_DEMARRAGE=45`) :
pendant ce temps, `/healthz` et `/readyz` répondent 503. C'est la réalité de l'appli,
pas un défaut : les sondes doivent s'y adapter.

> 🎯 **Cet atelier contient 3 défauts**, tous dans les sondes.
> **Deux** empêchent d'obtenir des pods prêts : à corriger dans cette partie.
> **Le troisième** ne se voit pas tant que tout va bien ; l'expérience de la
> partie C le révélera.
>
> Mode **boîte noire** (recommandé) ou **relecture**, au choix.

### Étape 1 — Appliquer et observer

```bash
kubectl apply -f depart/01-api-paiements-sondes.yaml
```

Sortie attendue :

```
deployment.apps/api-paiements configured
```

Observez le second terminal pendant 1 à 2 minutes. Que deviennent le nouveau pod ?
Et les anciens ? Le portail répond-il toujours ?

```bash
curl -s -H 'Host: portail.localhost' $ENTREE/appel
kubectl rollout status deployment/api-paiements --timeout=20s
```

### Étape 2 — Diagnostiquer et corriger

Vos outils :

```bash
kubectl describe pod <nouveau-pod>          # sections Liveness / Readiness, puis Events
kubectl get events --sort-by=.lastTimestamp | tail -20
kubectl logs <nouveau-pod> --previous       # journaux avant le dernier redémarrage
kubectl explain deployment.spec.template.spec.containers.startupProbe
kubectl exec deploy/portail-client -- wget -qO- http://<IP-du-pod>:8080/<route>
```

Contraintes :

- **ne retirez pas** `DELAI_DEMARRAGE` : on ne change pas l'appli, on règle ses sondes ;
- une fois l'appli démarrée, la liveness doit rester **rapide** : un blocage doit
  provoquer un redémarrage en 30 secondes au plus ;
- prévoyez au moins **60 secondes** pour le démarrage.

Corrigez **votre copie** de `depart/01-api-paiements-sondes.yaml`, réappliquez, et
recommencez jusqu'à obtenir dans le second terminal :

```
NAME                             READY   STATUS    RESTARTS   AGE
api-paiements-7f9c6d5b8-2xkqp    1/1     Running   0          2m40s
api-paiements-7f9c6d5b8-9hn4v    1/1     Running   0          1m50s
api-paiements-7f9c6d5b8-tq7wz    1/1     Running   0          60s
```

et :

```bash
kubectl rollout status deployment/api-paiements
```

```
deployment "api-paiements" successfully rolled out
```

> ⏱️ Chaque pod met 45 s à devenir prêt et le rollout les remplace un par un : comptez
> environ **2 min 30** pour un rollout complet. Patience avant de conclure.

---

## Partie C — Expérience : la dépendance tombe (15 min)

On simule une panne de la base de données : `READINESS_ECHOUE_APRES=60` fait passer
`/readyz` en 503 **60 secondes après le démarrage**, définitivement. `/healthz`, lui,
continue de répondre 200 : le processus va bien, c'est sa dépendance qui est tombée.

### Étape 3 — Avec la liveness du fichier de départ

Pour cette étape, la `livenessProbe` doit interroger la **même route que dans le
fichier de départ** (`path: /readyz`). Si vous l'aviez déjà modifiée, remettez-la
temporairement.

Ajoutez la variable dans la liste `env` de votre fichier :

```yaml
            - name: READINESS_ECHOUE_APRES
              value: "60"
```

puis :

```bash
kubectl apply -f depart/01-api-paiements-sondes.yaml
```

Observez le second terminal pendant **3 minutes**, et pendant ce temps :

```bash
kubectl describe pod <un-pod> | tail -15
curl -s -H 'Host: portail.localhost' $ENTREE/appel
```

Notez ce que vous voyez : colonne `READY`, colonne `RESTARTS`, événements.

### Étape 4 — Avec la liveness corrigée

Faites pointer la liveness sur la bonne route, gardez `READINESS_ECHOUE_APRES`, réappliquez,
et observez à nouveau **3 minutes** :

```bash
kubectl get endpointslices -l kubernetes.io/service-name=api-paiements -o yaml | grep 'ready:'
```

Comparez avec l'étape 3. Le rollout peut sembler bloqué : c'est normal, les nouveaux
pods ne restent prêts que 15 secondes (entre 45 s et 60 s).

| | Étape 3 | Étape 4 |
|---|---|---|
| Colonne `READY` après 60 s | | |
| Colonne `RESTARTS` après 3 min | | |
| Le portail obtient-il une réponse ? | | |
| Le redémarrage a-t-il réparé la base ? | | |

### Étape 5 — Fin de la panne

**Retirez `READINESS_ECHOUE_APRES`** de votre fichier, réappliquez, et attendez la fin
du rollout (environ 2 min 30) :

```bash
kubectl apply -f depart/01-api-paiements-sondes.yaml
kubectl rollout status deployment/api-paiements
```

Sortie attendue :

```
deployment.apps/api-paiements configured
Waiting for deployment "api-paiements" rollout to finish: 1 out of 3 new replicas have been updated...
...
deployment "api-paiements" successfully rolled out
```

---

## Bilan — À remplir

| Sonde | Question qu'elle pose | Sanction en cas d'échec | Route utilisée ici |
|---|---|---|---|
| startup | | | |
| liveness | | | |
| readiness | | | |

Et en une phrase : pourquoi une liveness sur `/readyz` cause-t-elle plus d'incidents
qu'elle n'en résout ?

## Critères de réussite

```bash
./verifier.sh
```

Le script contrôle :

1. `api-paiements` a 3 pods `Ready`, rollout terminé.
2. Aucun de ces pods n'a redémarré.
3. Le démarrage lent est conservé (`DELAI_DEMARRAGE=45`).
4. Une `startupProbe` est présente, avec un budget d'au moins 60 s.
5. La liveness interroge `/healthz`, la readiness `/readyz`.
6. Aucune variable d'expérience ne reste (`READINESS_ECHOUE_APRES`, `LIVENESS_ECHOUE_APRES`).
7. Le Service `api-paiements` a 3 endpoints prêts.

Sortie attendue :

```
✅ Deployment api-paiements : 3/3 pods Ready, rollout terminé
✅ Pods api-paiements : 0 restart
✅ Démarrage lent conservé (DELAI_DEMARRAGE=45)
✅ startupProbe présente, budget 75 s (minimum : 60 s)
✅ Liveness sur /healthz
✅ Readiness sur /readyz
✅ Aucune variable d'expérience restante
✅ Service api-paiements : 3 endpoints prêts

🎉 Atelier 3 réussi.
```

(Le budget affiché dépend de vos valeurs.)

## Bonus

Avec **vos** valeurs de liveness, calculez le délai maximal entre un blocage de
l'appli et son redémarrage (`periodSeconds × failureThreshold`). Vérifiez-le au
chronomètre :

1. Ajoutez `LIVENESS_ECHOUE_APRES=90` (`/healthz` passe en 503 90 s après le démarrage).
2. Réappliquez, notez l'heure de démarrage d'un nouveau pod, puis l'heure de son
   premier redémarrage :
   ```bash
   kubectl get events --sort-by=.lastTimestamp | grep -E 'Started|Killing'
   ```
3. L'écart moins 90 s doit être proche de votre calcul. Pourquoi pas exactement ?
4. **Retirez `LIVENESS_ECHOUE_APRES`** et réappliquez avant de relancer `./verifier.sh`.

## En cas de besoin

- Repartir de zéro : `./reset.sh` (revient à l'état de fin de l'atelier 2)
- Rattraper le groupe : `kubectl apply -f depart/00-socle.yaml -f solution/`
  (à demander au formateur)
