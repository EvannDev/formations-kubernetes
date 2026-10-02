# Atelier 2 — Exposition et DNS

## Objectif

Faire appeler `api-paiements` par le portail client `portail-client`, puis exposer
`portail-client` hors du cluster.

**Durée** : 1 h

| Partie | Durée |
|---|---|
| A — Déployer le portail, premier test par port-forward | 10 min |
| B — Faire parler le portail à l'API (DNS, Services) | 35 min |
| C — Exposer le portail avec un Ingress | 15 min |

## Prérequis

- Atelier 1 terminé : `../atelier-1-deployment-service/verifier.sh` entièrement vert.
  Sinon, rattrapez l'état de fin de l'atelier 1 :
  ```bash
  kubectl apply -f depart/00-socle.yaml
  ```
- Vous êtes dans le dossier de l'atelier :
  ```bash
  cd atelier-2-exposition-dns
  ```

## Mise en place

```bash
export NS=bdc
kubectl config set-context --current --namespace=$NS
```

Sortie attendue :

```
Context "default" modified.
```

---

> 🎯 **Cet atelier contient 3 défauts**, répartis dans les fichiers de `depart/`.
> L'API les accepte tous : aucun ne se voit avec `--dry-run=server`.
>
> Choisissez votre mode : **boîte noire** (recommandé : appliquez, testez,
> diagnostiquez, n'ouvrez un fichier qu'en dernier) ou **relecture** (lisez d'abord).

## Partie A — Déployer le portail, premier test par port-forward (10 min)

| Fichier | Contenu |
|---|---|
| `01-portail-client.yaml` | Deployment `portail-client`, 2 réplicas ; appelle l'API via `URL_AMONT` |
| `02-service-api.yaml` | Nouvelle version du Service `api-paiements` (ports nommés) : **remplace** celle de l'atelier 1 |
| `03-service-portail.yaml` | Service `portail-client`, ClusterIP |
| `04-ingress.yaml` | Ingress de `portail-client` — **pas avant la partie C** |

### Étape 1 — Appliquer le portail et les Services

```bash
kubectl apply -f depart/01-portail-client.yaml -f depart/02-service-api.yaml -f depart/03-service-portail.yaml
kubectl get pods -l app.kubernetes.io/part-of=bdc-paiements
```

Sortie attendue (les noms varient) :

```
deployment.apps/portail-client created
service/api-paiements configured
service/portail-client created
NAME                              READY   STATUS    RESTARTS   AGE
api-paiements-6d8f7c9b5d-9wq7m    1/1     Running   0          50m
api-paiements-6d8f7c9b5d-tz8hn    1/1     Running   0          50m
api-paiements-6d8f7c9b5d-xk4rb    1/1     Running   0          45m
portail-client-5b7d9c8f4-hx2lq    1/1     Running   0          15s
portail-client-5b7d9c8f4-p8wzt    1/1     Running   0          15s
```

`configured` (et non `created`) pour `api-paiements` : le Service existait, `apply`
l'a mis à jour.

### Étape 2 — Ouvrir un tunnel vers le portail (commande impérative imposée)

Dans un **second terminal**, laissé ouvert :

```bash
kubectl port-forward svc/portail-client 8080:80
```

Sortie attendue :

```
Forwarding from 127.0.0.1:8080 -> 8080
Forwarding from [::1]:8080 -> 8080
```

Dans le premier terminal (ou dans le navigateur, sur `http://localhost:8080`) :

```bash
curl -s http://localhost:8080/
```

Sortie attendue :

```
{"appli":"portail-client","version":"1.0","pod":"portail-client-5b7d9c8f4-hx2lq","namespace":"bdc"}
```

> ℹ️ `port-forward` est un tunnel de dépannage : il passe par l'API server et vise
> **un seul pod**, choisi au démarrage. Relancez `curl` : le champ `pod` ne change
> pas. Ce n'est pas ainsi qu'on expose une application (voir partie C).

---

## Partie B — Faire parler le portail à l'API (35 min)

La route `/appel` du portail appelle l'API de paiements et renvoie sa réponse, ou
l'**erreur exacte** rencontrée.

### Étape 3 — Faire fonctionner `/appel`

```bash
curl -s http://localhost:8080/appel
```

Corrigez jusqu'à obtenir (les noms et durées varient) :

```
{"url":"http://api-paiements","statut_amont":200,"duree_ms":3,"reponse":{"appli":"api-paiements","version":"1.0","pod":"api-paiements-6d8f7c9b5d-tz8hn","namespace":"bdc"}}
```

Lisez attentivement le champ `type` et le message `erreur` : ils indiquent à quelle
étape l'appel échoue. Vos outils :

```bash
# Ce que voit un pod du portail
kubectl exec deploy/portail-client -- cat /etc/resolv.conf
kubectl exec deploy/portail-client -- nslookup <nom-complet>.svc.cluster.local
kubectl exec deploy/portail-client -- wget -qO- -T 5 http://<adresse>:<port>/

# Ce que fait le Service
kubectl describe svc api-paiements
kubectl get endpointslices -l kubernetes.io/service-name=api-paiements
kubectl get pods -o wide                      # adresses IP des pods
```

> 💡 Après une modification du Deployment `portail-client`, de nouveaux pods
> remplacent les anciens et le tunnel de l'étape 2 se coupe
> (`lost connection to pod`). Relancez-le.

### Étape 4 — Explorer le DNS du cluster

Une fois `/appel` fonctionnel, regardez comment un pod résout les noms :

```bash
kubectl exec deploy/portail-client -- cat /etc/resolv.conf
```

Sortie attendue :

```
search bdc.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.43.0.10
options ndots:5
```

- `nameserver` : l'adresse du DNS du cluster (CoreDNS).
- `search` : les suffixes ajoutés automatiquement à un nom court.

Les trois formes suivantes désignent donc le même Service. Vérifiez-le :

```bash
kubectl exec deploy/portail-client -- wget -qO- http://api-paiements/
kubectl exec deploy/portail-client -- wget -qO- http://api-paiements.bdc/
kubectl exec deploy/portail-client -- wget -qO- http://api-paiements.bdc.svc.cluster.local/
```

Sortie attendue (trois fois, le champ `pod` varie) :

```
{"appli":"api-paiements","version":"1.0","pod":"api-paiements-6d8f7c9b5d-9wq7m","namespace":"bdc"}
```

Comparez avec l'adresse du Service :

```bash
kubectl exec deploy/portail-client -- nslookup api-paiements.bdc.svc.cluster.local
kubectl get svc api-paiements
```

Sortie attendue : la même adresse (10.43.x.x) dans les deux cas — l'adresse stable du
Service, jamais celle d'un pod.

| Forme | Fonctionne depuis |
|---|---|
| `api-paiements` | le même namespace uniquement |
| `api-paiements.bdc` | n'importe quel namespace du cluster |
| `api-paiements.bdc.svc.cluster.local` | n'importe quel namespace du cluster (forme complète, FQDN) |

---

## Partie C — Exposer le portail avec un Ingress (15 min)

Un Ingress est une règle de routage HTTP : Traefik, le contrôleur Ingress de k3s,
reçoit les requêtes sur les ports 80/443 du poste et les envoie au bon Service selon
l'en-tête `Host`.

### Étape 5 — Trouver l'entrée du cluster

**Sur Linux natif**, Traefik écoute directement sur le port 80 du poste :

```bash
export ENTREE=http://localhost
```

**Sous WSL**, ouvrez d'abord un tunnel vers Traefik dans un terminal dédié, laissé ouvert :

```bash
kubectl port-forward -n kube-system svc/traefik 8081:80
```

puis, dans votre terminal de travail :

```bash
export ENTREE=http://localhost:8081
```

Dans les deux cas, vérifiez que Traefik répond :

```bash
curl -s $ENTREE/
```

Sortie attendue (aucune règle ne correspond encore) :

```
404 page not found
```

### Étape 6 — Appliquer l'Ingress et le faire fonctionner

```bash
kubectl apply -f depart/04-ingress.yaml
kubectl get ingress
curl -s -H 'Host: portail.localhost' $ENTREE/
```

Corrigez jusqu'à obtenir :

```
NAME             CLASS     HOSTS               ADDRESS        PORTS   AGE
portail-client   traefik   portail.localhost   172.20.10.5    80      30s
{"appli":"portail-client","version":"1.0","pod":"portail-client-5b7d9c8f4-p8wzt","namespace":"bdc"}
```

(L'adresse `ADDRESS` est celle de votre poste ; elle varie.)

Vos outils :

```bash
kubectl describe ingress portail-client
kubectl describe svc portail-client
kubectl logs -n kube-system deploy/traefik --tail=20
```

Ouvrez ensuite le portail dans votre navigateur : `http://portail.localhost`
(sous WSL : `http://portail.localhost:8081`). Testez aussi `/appel`.

### Étape 7 — Deux 404 qui ne se ressemblent pas

```bash
curl -s -H 'Host: portail.localhost' $ENTREE/inexistant
curl -s -H 'Host: autre.localhost' $ENTREE/
```

Sortie attendue :

```
{"erreur":"route inconnue","appli":"portail-client","pod":"portail-client-5b7d9c8f4-hx2lq","chemin":"/inexistant"}
404 page not found
```

- Le premier 404 vient **de l'appli** : la requête a traversé Traefik, le Service et
  le pod. C'est la route qui n'existe pas.
- Le second vient **de Traefik** : aucune règle d'Ingress ne correspond, la requête
  n'est jamais arrivée au cluster applicatif.

Savoir lequel des deux on reçoit, c'est savoir où chercher.

---

## Critères de réussite

```bash
./verifier.sh
```

Le script contrôle :

1. `portail-client` a 2 pods `Ready`.
2. Le Service `api-paiements` envoie le trafic au port 8080 des pods.
3. `/appel` sur le portail reçoit la réponse de `api-paiements`.
4. L'Ingress répond HTTP 200 avec la page du portail sur `http://portail.localhost`.

Sortie attendue :

```
✅ Deployment portail-client : 2/2 pods Ready
✅ Service api-paiements : trafic envoyé au port 8080 des pods
✅ portail-client/appel reçoit la réponse de api-paiements
✅ Ingress portail-client : http://portail.localhost répond HTTP 200 avec la page de portail-client

🎉 Atelier 2 réussi.
```

## Bonus

1. **Le voisin est joignable.** Déployez une copie de l'API dans un autre namespace,
   puis appelez-la depuis le portail :
   ```bash
   kubectl create namespace bdc-voisin
   kubectl apply -n bdc-voisin -f depart/00-socle.yaml
   kubectl exec deploy/portail-client -- wget -qO- http://api-paiements.bdc-voisin/
   ```
   La réponse indique `"namespace":"bdc-voisin"`. Rien n'empêche un pod d'appeler
   n'importe quel Service d'un autre namespace : un namespace **n'isole pas le
   réseau**. C'est le rôle des NetworkPolicy (formation 2).
2. **Voir les flux avec Hubble.** Ouvrez `http://hubble.localhost` (sous WSL :
   `http://hubble.localhost:8081`), choisissez le namespace `bdc`, puis relancez
   quelques `/appel`. Hubble affiche chaque flux `portail-client → api-paiements`.
   Refaites le bonus 1 et observez le flux qui sort vers `bdc-voisin`.
3. **NodePort (commande impérative imposée).**
   ```bash
   kubectl expose deployment portail-client --name=portail-nodeport --type=NodePort --port=80 --target-port=http
   kubectl get svc portail-nodeport
   ```
   Notez le port attribué (30000–32767) dans la colonne `PORT(S)`, puis :
   `curl -s http://localhost:<port>/`.

   > ⚠️ **Pratique à éviter en production** : un NodePort ouvre le même port sur
   > **chaque** nœud, hors de tout contrôle HTTP (pas de nom d'hôte, pas de TLS
   > centralisé), dans une plage de ports peu lisible. On lui préfère un Ingress.
   >
   > De même, `--type=LoadBalancer` fonctionne sur votre poste grâce au ServiceLB
   > de k3s, mais ce n'est **pas représentatif** d'un cloud, où chaque Service
   > `LoadBalancer` crée un répartiteur de charge facturé.

   Nettoyez : `kubectl delete svc portail-nodeport`.

## En cas de besoin

- Repartir de zéro : `./reset.sh` (revient à l'état de fin de l'atelier 1)
- Rattraper le groupe : `kubectl apply -f depart/00-socle.yaml -f solution/`
  (à demander au formateur)
