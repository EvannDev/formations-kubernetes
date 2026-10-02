# Image de formation `formations-kubernetes/app`

Une seule application Go pour tous les ateliers de la formation Kubernetes BDC.
Son comportement (démarrage lent, sondes en échec, consommation CPU ou mémoire,
appel d'un service amont…) se règle par variables d'environnement : les manifests
des ateliers n'utilisent jamais d'autre image.

Registre : `ghcr.io/evanndev/formations-kubernetes/app`

| Tag | Variante | Utilisée en |
|---|---|---|
| `1.0`, `1.1` | `shell` — Alpine, avec `sh`, `wget`, `nslookup` | F1, F2 |
| `1.0-distroless`, `1.1-distroless` | `distroless` — aucun shell ni outil | F3 |

`1.0` et `1.1` ne diffèrent que par la version affichée : elles servent au rollout
de l'atelier 1. Il n'y a **jamais** de tag `latest`, et **jamais** de tag `1.O`
(lettre O) : l'atelier 5 s'appuie sur son absence. Le `Makefile` refuse de le créer.

Les deux variantes tournent en utilisateur non root (UID 65532), pour amd64 et arm64.

## Routes (port 8080)

| Route | Réponse |
|---|---|
| `/` | `{"appli":…,"version":…,"pod":…,"namespace":…}` |
| `/healthz` | liveness : 200, ou 503 (démarrage lent, `LIVENESS_ECHOUE_APRES`) |
| `/readyz` | readiness : 200, ou 503 (démarrage lent, `READINESS_ECHOUE_APRES`) |
| `/info` | identité, variables d'environnement (secrets masqués), limites cgroup, mémoire retenue |
| `/brule?secondes=N&fils=M` | consomme M cœurs pendant N s (défauts : 10 s, 1 fil ; max 300 s, 64 fils) |
| `/memoire?mo=N` | alloue N Mo et les conserve (1 à 4096) |
| `/appel` | appelle `URL_AMONT` ; renvoie sa réponse, ou HTTP 502 avec le type d'erreur (`dns`, `refus`, `timeout`, `autre`) et le message exact |
| *(autre)* | 404 `{"erreur":"route inconnue",…}` |

Les sondes ne sont pas journalisées ; toutes les autres requêtes le sont (une ligne
chacune). L'application s'arrête proprement sur `SIGTERM`.

## Variables d'environnement

Les durées sont en secondes et partent du démarrage du conteneur. Absente ou `0` :
comportement désactivé.

| Variable | Effet |
|---|---|
| `NOM_APPLI` | nom affiché par `/` (défaut : `formations-kubernetes`) |
| `VERSION_AFFICHEE` | version affichée par `/` (défaut : le tag de l'image) |
| `EXIGE_VARS` | liste de variables obligatoires, séparées par des virgules ; si une manque, arrêt immédiat avec `ERREUR : variable obligatoire absente : …` |
| `CRASH_AU_DEMARRAGE` | arrêt volontaire (code 1) après N s |
| `DELAI_DEMARRAGE` | démarrage lent simulé : `/healthz` et `/readyz` en 503 pendant N s |
| `READINESS_ECHOUE_APRES` | `/readyz` passe en 503 après N s, définitivement |
| `LIVENESS_ECHOUE_APRES` | `/healthz` passe en 503 après N s, définitivement |
| `BALLON_MEMOIRE_MO` | alloue et conserve N Mo au démarrage (atelier 4 : `OOMKilled`) |
| `URL_AMONT` | cible de `/appel` |

Une valeur invalide (`DELAI_DEMARRAGE=abc`) arrête l'application avec un message explicite.

## Construire et publier

Prérequis : Docker avec buildx (Docker Desktop convient). Go n'est pas nécessaire :
la compilation et les tests se font dans un conteneur.

```bash
make test          # gofmt, go vet et tests unitaires
make build         # images locales, architecture de cette machine
make push          # images amd64 + arm64 poussées vers ghcr.io
make list          # vérifie les tags publiés et leurs architectures
```

La construction lance aussi `go vet` et les tests : une image ne sort jamais si un
test échoue.

### Première publication sur ghcr.io

1. Créer un jeton GitHub (*Settings → Developer settings → Personal access tokens*,
   jeton classique) avec la portée `write:packages`.
2. Se connecter :
   ```bash
   echo "$JETON_GITHUB" | docker login ghcr.io -u EvannDev --password-stdin
   ```
3. `make push`
4. **Rendre le paquet public** : un paquet ghcr.io est privé à sa création. Sur
   GitHub : *Packages → formations-kubernetes/app → Package settings → Change visibility →
   Public*. Sinon, k3s ne peut pas tirer l'image sans secret
   (`ImagePullBackOff`… et l'atelier 5 perd son effet de surprise).

Le label `org.opencontainers.image.source` relie le paquet au dépôt
`EvannDev/formations-kubernetes`.

## Essai local

```bash
docker run --rm -p 8080:8080 -e NOM_APPLI=api-paiements ghcr.io/evanndev/formations-kubernetes/app:1.0
curl localhost:8080/
curl localhost:8080/ready          # 404 : route inconnue

docker run --rm -e EXIGE_VARS=BD_MOT_DE_PASSE ghcr.io/evanndev/formations-kubernetes/app:1.0
# ERREUR : variable obligatoire absente : BD_MOT_DE_PASSE (EXIGE_VARS=BD_MOT_DE_PASSE)
```
