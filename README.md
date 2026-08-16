# tout-pris-docker

Déploiement de la stack **Tout Pris** : le backend
[`tout-pris-back`](https://github.com/Haelle/tout-pris-back) (FastAPI), le front
[`tout-pris-front`](https://github.com/Haelle/tout-pris-front) (SvelteKit
statique), la base de données, un reverse proxy nginx et les sauvegardes.

Ce dépôt ne contient pas de code applicatif : uniquement les fichiers
d'infrastructure.

## Architecture

```
                     ┌──────────────────────────────────────────────┐
                     │              réseau « toutpris »             │
  internet ──▶ nginx │                                              │
              :80/443├──▶ front  :80    (nginx + SPA SvelteKit)      │
                     │                                              │
                     ├──▶ api    :8000  (uvicorn + FastAPI)         │
                     │              │                               │
                     │              ▼                               │
                     │     volume db_data (SQLite, mode WAL)        │
                     │              ▲                               │
                     │     backup ──┘  ──▶ ./backups/*.sqlite.gz    │
                     └──────────────────────────────────────────────┘
```

**Seul `nginx` publie des ports.** `api` et `front` ne sont joignables que
depuis le réseau interne.

Le front et l'API sont servis **depuis la même origine** : le SPA appelle
`/api/<chemin>`, nginx retire le préfixe et route vers FastAPI qui expose
`<chemin>` à sa racine. Pas de CORS, pas d'URL d'API à configurer dans le front.

`tout-pris-back` stocke tout dans **SQLite** — un fichier unique dans le volume
`db_data`, pas de serveur de base séparé. Il n'y a donc pas de service `db` :
la « base » est ce volume, et c'est lui qu'on sauvegarde.

## Démarrage

```sh
cp .env.example .env          # ajuster les tags d'images et les ports
docker compose up -d
docker compose ps
```

Le site répond alors sur `http://localhost` (port configurable via
`HTTP_PORT`) :

| URL | Sert |
| --- | --- |
| `/` | le SPA |
| `/api/stufflists` | l'API FastAPI |
| `/api/docs` | la doc interactive Swagger |
| `/healthz` | la santé du proxy |

```sh
docker compose logs -f --tail=100          # tous les services
docker compose logs -f --tail=100 api      # un seul
docker compose down                        # arrêt (les volumes sont conservés)
```

## Configuration

Tout passe par `.env` (voir [`.env.example`](.env.example)) :

| Variable | Défaut | Rôle |
| --- | --- | --- |
| `API_IMAGE` / `API_TAG` | `estb/tout-pris-back:latest` | image du backend |
| `FRONT_IMAGE` / `FRONT_TAG` | `estb/tout-pris-front:latest` | image du front |
| `HTTP_PORT` / `HTTPS_PORT` | `80` / `443` | ports publiés par nginx |
| `DATABASE_URL` | `sqlite:////data/tout_pris.db` | base utilisée par l'API |
| `BACKUP_INTERVAL` | `86400` | secondes entre deux sauvegardes |
| `BACKUP_RETENTION` | `14` | archives conservées |
| `HEALTHCHECK_URL` | *(vide)* | ping de supervision après sauvegarde |
| `TZ` | `Europe/Paris` | fuseau du planificateur Watchtower |

Les tags publiés par la CI des deux dépôts : `dev` suit `main`, `latest` suit le
dernier tag git, et les tags semver (`1`, `1.2`, `1.2.3`) permettent d'épingler.
Le choix du tag détermine la stratégie de mise à jour (voir ci-dessous) : un tag
semver rend les déploiements explicites et les rollbacks triviaux, un tag mobile
est ce qu'attend Watchtower. Il faut choisir — pas les deux.

## Mise à jour

### Manuelle

```sh
docker compose pull
docker compose up -d --remove-orphans
docker compose ps
```

Les migrations Alembic sont appliquées automatiquement au démarrage de l'API
(`command.upgrade(…, "head")` dans son `lifespan`).

### Automatique, avec Watchtower

Les services `api` et `front` portent le label
`com.centurylinklabs.watchtower.enable=true`. Le service `watchtower`
correspondant est **fourni commenté en fin de [`compose.yaml`](compose.yaml)** :
il suffit de le décommenter pour que les mises à jour se fassent seules.

Combiné à `WATCHTOWER_LABEL_ENABLE=true`, ce label restreint Watchtower à ces
deux conteneurs : `nginx` et `backup` ne seront pas touchés. `nginx` est
délibérément laissé de côté — c'est le seul service exposé, et une recréation
coupe les connexions en cours ; son label est présent mais commenté si vous
préférez l'inverse. Quant à `backup`, il est construit localement : il n'y a pas
de registre à surveiller.

Trois points avant de décommenter :

- **Le tag doit être mobile.** Avec `API_TAG=1.2.3`, le digest ne change jamais
  et Watchtower ne fera strictement rien. Il faut `dev` (suit `main`) ou
  `latest` (suit le dernier tag git).
- **Le socket Docker donne un accès équivalent à root sur l'hôte.** C'est le
  compromis inhérent à l'auto-update, à accepter en connaissance de cause.
- **Commencez en observation.** `WATCHTOWER_MONITOR_ONLY=true` (présent
  commenté) signale ce qui serait mis à jour sans rien recréer.

La recréation d'un conteneur lui donne une nouvelle IP interne, sans
conséquence ici : la configuration nginx re-résout les noms de services à
chaque requête (voir la note sur `resolver` plus bas). Sans ça, chaque mise à
jour automatique laisserait le proxy en 502.

Un point à garder en tête : une nouvelle image du backend peut embarquer une
migration Alembic, appliquée sans supervision au redémarrage. C'est une raison
de plus de garder le service `backup` actif — et, si les migrations deviennent
lourdes, de repasser en mise à jour manuelle.

## nginx

| Fichier | Rôle |
| --- | --- |
| [`nginx/nginx.conf`](nginx/nginx.conf) | configuration globale : logs, gzip, rate limiting, résolveur DNS |
| [`nginx/conf.d/tout-pris.conf`](nginx/conf.d/tout-pris.conf) | vhost HTTP (celui qui est actif) |
| [`nginx/conf.d/tout-pris-tls.conf.example`](nginx/conf.d/tout-pris-tls.conf.example) | variante HTTPS, inerte tant qu'elle garde l'extension `.example` |

Quelques choix qui méritent une explication :

- **`resolver 127.0.0.11` + `set $upstream …`** — sans ça, nginx résout les noms
  de services une seule fois au démarrage et garde l'IP en cache indéfiniment.
  Un `docker compose up -d api` change l'IP du conteneur et laisse le proxy en
  502 jusqu'à un rechargement manuel. Passer par une variable force la
  re-résolution.
- **`location ~ ^/api/(.*)$`** — la capture `$1` retire le préfixe `/api` avant
  de proxifier, ce que le front attend (en dev, c'est le proxy Vite qui fait la
  même réécriture).
- **`--root-path=/api`** sur uvicorn (dans `compose.yaml`) — FastAPI sait ainsi
  qu'il est monté derrière un préfixe, ce qui rend `/api/docs` et
  `/api/openapi.json` fonctionnels à travers le proxy.
- **`limit_req zone=api`** — 20 req/s par IP avec une rafale de 40, pour éviter
  qu'un client unique sature l'API.

Après toute modification, vérifier la syntaxe **avant** de recharger — un
`reload` sur une configuration invalide est refusé, mais autant le savoir tout
de suite :

```sh
docker compose exec nginx nginx -t
docker compose exec nginx nginx -s reload    # recharge sans couper les connexions
```

### HTTPS

1. Adapter le domaine dans `nginx/conf.d/tout-pris-tls.conf.example` (le
   fichier contient la procédure complète en commentaire).
2. Obtenir un certificat via le challenge HTTP-01 — le vhost HTTP sert déjà
   `/.well-known/acme-challenge/` depuis le volume `certbot_webroot` :

   ```sh
   docker run --rm \
     -v tout-pris_certbot_webroot:/var/www/certbot \
     -v ./nginx/certs:/etc/letsencrypt \
     certbot/certbot certonly --webroot -w /var/www/certbot \
     -d tout-pris.example.com --email vous@example.com --agree-tos
   ```

3. Activer le vhost TLS et désactiver celui en clair :

   ```sh
   mv nginx/conf.d/tout-pris.conf nginx/conf.d/tout-pris.conf.disabled
   cp nginx/conf.d/tout-pris-tls.conf.example nginx/conf.d/tout-pris-tls.conf
   docker compose exec nginx nginx -t && docker compose exec nginx nginx -s reload
   ```

4. Programmer le renouvellement (`certbot renew` puis un `nginx -s reload`) dans
   une crontab de l'hôte.

> Si la stack tourne derrière un proxy qui gère déjà le TLS (Traefik, Caddy,
> load balancer d'hébergeur), gardez le vhost HTTP tel quel et ne publiez que
> `HTTP_PORT`.

## Sauvegardes

Le service `backup` écrit dans `./backups` une copie datée, vérifiée et
compressée de la base, toutes les `BACKUP_INTERVAL` secondes, en ne conservant
que les `BACKUP_RETENTION` dernières.

```sh
docker compose up backup-once    # sauvegarde immédiate, puis le conteneur s'arrête
ls -lh backups/                  # archives disponibles
```

`backup-once` et `restore` sont derrière le profil `tools` : ils ne démarrent
pas avec `docker compose up -d`, uniquement quand on les nomme.

Il utilise `sqlite3 .backup`, c'est-à-dire l'**API de sauvegarde en ligne** de
SQLite : elle produit un fichier cohérent pendant que l'API continue d'écrire.
Copier le `.db` à la main (`cp`, `tar`, `docker cp`) n'offre aucune garantie —
les dernières transactions vivent dans le `-wal`, qui n'est pas copié
atomiquement avec le fichier principal, et rien ne signale le problème au
moment de la copie. Chaque archive est relue avec `PRAGMA integrity_check`
avant d'être conservée, et n'est renommée sous son nom définitif qu'en cas de
succès : le dossier ne contient donc jamais d'archive tronquée.

Deux points restent à votre charge : les archives sont sur le **même disque**
que la base — un `rclone`/`restic` vers un stockage distant depuis une crontab
de l'hôte est le complément minimal — et `HEALTHCHECK_URL` doit pointer vers un
service type [healthchecks.io](https://healthchecks.io), sans quoi une
sauvegarde qui échoue le fait en silence.

## Restaurer la base

Procédure manuelle, à faire depuis le dossier du dépôt sur le serveur.

**1. Choisir l'archive.**

```sh
ls -lh backups/
# tout_pris-20260816T031500Z.sqlite.gz
```

**2. Arrêter tout ce qui écrit dans la base.** `nginx` peut rester en place, il
renverra des 502 le temps de l'opération.

```sh
docker compose stop api backup
```

**3. Lancer la restauration**, en passant le nom du fichier (le `.gz` est
accepté tel quel, pas besoin de le décompresser).

```sh
ARCHIVE=tout_pris-20260816T031500Z.sqlite.gz docker compose up restore
```

Le service `restore` enchaîne, dans cet ordre :

1. décompression de l'archive dans un fichier de travail — l'original reste
   intact même si la suite échoue ;
2. `PRAGMA integrity_check` sur cette copie, et **arrêt immédiat** si elle est
   inutilisable. C'est le point important : une restauration qui échoue après
   avoir écrasé la base en place est une double panne ;
3. mise de côté de la base actuelle dans
   `backups/avant-restauration-<horodatage>.sqlite.gz` — même une base qu'on
   croit perdue peut contenir des écritures plus récentes que l'archive. Ce nom
   ne correspond pas au motif de rotation, cette copie ne sera donc jamais
   purgée automatiquement ;
4. suppression des `-wal`/`-shm` résiduels, qui appartiennent à l'ancienne base
   et feraient rejouer à SQLite un journal ne correspondant plus au fichier
   restauré, puis installation de l'archive avec un `chown 999:999`
   (l'utilisateur non-root de l'image de production de `tout-pris-back`).

Sans `ARCHIVE`, le script s'arrête en listant les archives disponibles. La
logique est dans [`backup/restore.sh`](backup/restore.sh), lisible d'un bout à
l'autre.

**4. Redémarrer et vérifier.**

```sh
docker compose up -d
docker compose logs -f api        # les migrations Alembic se rejouent au démarrage
curl -fsS http://localhost/api/health
curl -fsS http://localhost/api/stufflists
```

Restaurer une archive plus ancienne que le code déployé ne pose pas de
problème : l'API applique les migrations manquantes au démarrage
(`command.upgrade(…, "head")` dans son `lifespan`). L'inverse — restaurer une
base issue d'une version *plus récente* du backend — n'est pas géré, Alembic ne
sachant pas redescendre tout seul.

> Testez cette procédure au moins une fois **avant** d'en avoir besoin, sur une
> pile jetable (`docker compose -p toutpris-restore-test up -d`). C'est le seul
> moyen de savoir que vos archives sont exploitables.

## Développement local

Ce dépôt déploie les **images publiées**. Pour travailler sur le code, utilisez
les `docker-compose.yml` de chaque dépôt applicatif, qui montent les sources et
activent le rechargement à chaud.
