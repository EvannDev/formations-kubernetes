# Aide-mémoire — Formation 1

## Mise en place

```bash
export NS=bdc                                         # bdc-diagnostic pour l'atelier 5
kubectl config set-context --current --namespace=$NS
```

## La boucle de correction

```bash
kubectl apply --dry-run=server -f <fichier>   # l'API valide-t-elle ?
kubectl diff -f <fichier>                     # qu'est-ce que ma correction change ?
kubectl explain <ressource.chemin>            # nom exact et type du champ
kubectl apply -f <fichier>                    # appliquer
```

## Observer

```bash
kubectl get pods -w                           # suivre en direct (Ctrl+C)
kubectl get pods -o wide                      # + IP et nœud
kubectl get pods --show-labels                # + labels
kubectl get all                               # objets principaux du namespace
kubectl get events --sort-by=.lastTimestamp   # ce qui s'est passé, dans l'ordre
```

## Diagnostiquer

| Symptôme | Commande |
|---|---|
| L'API refuse le fichier | `kubectl apply --dry-run=server -f <fichier>` |
| `Pending`, `ImagePullBackOff`, `CreateContainerConfigError` | `kubectl describe pod <pod>` (section Events) |
| `CrashLoopBackOff`, `RESTARTS` qui montent | `kubectl logs <pod> --previous` |
| Service qui ne répond pas | `kubectl get endpointslices -l kubernetes.io/service-name=<svc>` + `kubectl describe svc <svc>` |
| `OOMKilled`, lenteur | `kubectl describe pod <pod>` (Last State) + `kubectl top pod` |
| PVC `Pending` | `kubectl describe pvc <pvc>` + `kubectl get storageclass` |

```bash
kubectl exec -it <pod> -- sh                  # shell dans un conteneur
kubectl exec <pod> -- nslookup <service>      # tester le DNS
kubectl exec <pod> -- wget -qO- http://<service>/   # tester un Service
kubectl run test --rm -it --restart=Never --image=ghcr.io/gologic/bdc-formation/app:1.0 \
  --command -- wget -qO- http://<service>     # pod jetable de test
```

## Agir (impératif)

```bash
kubectl create secret generic <nom> --from-literal=CLE=valeur
kubectl create secret generic <nom> --from-literal=CLE=valeur --dry-run=client -o yaml | kubectl apply -f -
kubectl scale deployment/<nom> --replicas=N
kubectl set image deployment/<nom> <conteneur>=<image>:<tag>
kubectl label pod <pod> cle=valeur --overwrite
kubectl expose deployment/<nom> --port=80 --target-port=8080
kubectl port-forward svc/<svc> 8080:80        # puis http://localhost:8080
kubectl patch deployment/<nom> -p '<json>'
kubectl edit deployment/<nom>                 # ⚠️ défait au prochain apply du fichier
```

## Rollout

```bash
kubectl rollout status  deployment/<nom>
kubectl rollout history deployment/<nom>
kubectl rollout undo    deployment/<nom>
kubectl rollout restart deployment/<nom>      # recharge Secret/ConfigMap injectés en variables
```

## Ressources et QoS

```bash
kubectl top pod
kubectl top node
kubectl describe node                         # Allocated resources : somme des requests
kubectl get pod -o custom-columns=NOM:.metadata.name,QOS:.status.qosClass
```

## Réflexes

- Le **fichier fait foi** : toute correction impérative doit être reportée dans le manifest.
- Un **selector** qui ne correspond à rien est valide : comparer avec `--show-labels`.
- Un **Secret** n'est pas chiffré : base64 se décode en une commande.
- Ne **jamais** toucher à `kube-system`.
