# Atelier 5 — Diagnostic en boîte noire

## Objectif

Remettre en service cinq applis en panne **sans ouvrir leurs manifests** : du
symptôme à la cause, avec `kubectl` seulement.

**Durée** : 1 h

| Partie | Durée |
|---|---|
| Consignes et déploiement | 5 min |
| Diagnostic | 45 min |
| Restitution | 10 min |

## Prérequis

- Aucun : cet atelier est autonome. Il travaille dans son propre namespace,
  `bdc-diagnostic`, sans toucher à `bdc`.
- Vous êtes dans le dossier de l'atelier :
  ```bash
  cd atelier-5-diagnostic
  ```

## Mise en place

```bash
export NS=bdc-diagnostic
./deployer-pannes.sh
kubectl config set-context --current --namespace=$NS
```

Sortie attendue :

```
✅ Cinq applis déployées dans le namespace « bdc-diagnostic ».

Laissez-leur 2 minutes, puis commencez par :
   kubectl get pods -n bdc-diagnostic
Context "default" modified.
```

Créez vos cinq fiches à partir du gabarit :

```bash
for appli in virements-interac notifications-client moteur-scoring releves-partenaires portefeuille-titres; do
  cp fiches/GABARIT.md fiches/$appli.md
done
```

## Les règles

> ⛔ **N'ouvrez ni `depart/pannes.yaml` ni `solution/`** avant la restitution.
>
> ✅ Toutes les commandes `kubectl` sont permises : `get`, `describe`, `logs`,
> `events`, `exec`, `top`, `explain`…

Les cinq applis :

| Appli | Rôle | |
|---|---|---|
| `virements-interac` | virements Interac entrants et sortants | |
| `notifications-client` | courriels et notifications aux clients | |
| `moteur-scoring` | scoring de crédit en temps réel | |
| `releves-partenaires` | relevés transmis aux partenaires | |
| `portefeuille-titres` | consultation du portefeuille de titres | **bonus** |

Chaque appli a **une** panne. Pour chacune :

1. Remplissez sa fiche `fiches/<appli>.md` : **symptôme → commande → cause → correctif**.
2. Corrigez **dans le cluster**, avec une commande impérative : `kubectl set image`,
   `kubectl set env`, `kubectl patch`, `kubectl edit`…
3. Notez dans la rubrique « Correctif » ce qu'il faudrait corriger **dans le fichier
   source** : en vrai, le prochain `kubectl apply` réintroduirait la panne.

> ⏱️ Certaines pannes ne se montrent pas tout de suite. Une appli qui semble saine
> après 30 secondes ne l'est peut-être plus après 3 minutes.

---

## La méthode

Trois questions, toujours dans cet ordre :

1. **Quel est l'état du pod ?**
   ```bash
   kubectl get pods
   kubectl get pods -w          # pour suivre l'évolution
   ```
2. **Quelle commande raconte son histoire ?** Elle dépend de l'état :

   | État | Commande qui raconte l'histoire |
   |---|---|
   | `Pending` | `kubectl describe pod <pod>` (Events : pourquoi il n'est placé nulle part) |
   | `ImagePullBackOff`, `ErrImagePull` | `kubectl describe pod <pod>` (Events : ce que le registre a répondu) |
   | `CrashLoopBackOff`, `Error` | `kubectl logs <pod> --previous` (ce que l'appli a dit avant de mourir) |
   | `Running` mais `0/1` | `kubectl describe pod <pod>` (quelle sonde échoue, quel code HTTP) |
   | `RESTARTS` qui monte | `kubectl describe pod <pod>` (Last State, Events) ; `kubectl get events --sort-by=.lastTimestamp` |

3. **Que dit la configuration ?**
   ```bash
   kubectl describe deployment <appli>      # image, variables, sondes, nodeSelector
   kubectl get configmap
   kubectl describe configmap <nom>
   kubectl get nodes --show-labels
   ```

Pour tester un Service de l'intérieur, utilisez une autre appli comme point de départ :

```bash
kubectl exec deploy/<une-appli-qui-tourne> -- wget -qO- -T 5 http://<service>/
```

---

## Critères de réussite

```bash
./verifier.sh
```

Le script contrôle, pour les quatre applis obligatoires :

1. un pod `Ready`, **stable depuis au moins 2 min 30** ;
2. une fiche remplie, sans rubrique vide.

`portefeuille-titres` (bonus) est affichée à part et ne compte pas dans le résultat.

Sortie attendue :

```
✅ virements-interac : Ready et stable
✅ virements-interac : fiche remplie
✅ notifications-client : Ready et stable
✅ notifications-client : fiche remplie
✅ moteur-scoring : Ready et stable
✅ moteur-scoring : fiche remplie
✅ releves-partenaires : Ready et stable
✅ releves-partenaires : fiche remplie

✅ Bonus portefeuille-titres : Ready, stable, fiche remplie ⭐

🎉 Atelier 5 réussi.
```

## Restitution (10 min)

Chaque binôme présente **une** appli en 2 minutes, avec sa fiche :

1. le symptôme observé ;
2. la commande qui a tout révélé ;
3. la cause ;
4. le correctif appliqué, et ce qu'il faudrait changer dans le fichier source.

## Bonus — Fermer la boucle

Une fois la restitution faite, vous avez le droit d'ouvrir `depart/pannes.yaml`.

```bash
kubectl diff -f depart/pannes.yaml
```

`kubectl diff` montre ce qu'un `apply` du fichier changerait dans le cluster : ici,
il remettrait vos cinq pannes. Corrigez le fichier jusqu'à ce que `kubectl diff` ne
montre plus rien d'essentiel : le fichier et le cluster disent alors la même chose.
Comparez ensuite avec `solution/pannes.yaml`.

## En cas de besoin

- Recommencer : `./reset.sh` puis `./deployer-pannes.sh` (vos fiches sont conservées)
- Rattraper : `kubectl apply -f solution/pannes.yaml` (à demander au formateur)
