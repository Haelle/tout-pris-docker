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

### À propos de la base de données

`tout-pris-back` utilise **SQLite** — un fichier unique dans le volume
`db_data`, pas de serveur de base séparé. Il n'y a donc pas de service `db`
dans `compose.yaml` : la « base » est le volume, et c'est lui qu'on sauvegarde.

Une surcouche PostgreSQL est fournie dans
[`compose.postgres.yaml`](compose.postgres.yaml), mais **elle ne peut pas
fonctionner en l'état** : le code du backend est SQLite-only. Les trois
modifications nécessaires côté `tout-pris-back` sont détaillées en tête de ce
fichier.

## Démarrage

```sh
cp .env.example .env    # ajuster les tags d'images et les ports
make up                 # ou : docker compose up -d
make ps
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
make logs           # tous les services
make logs s=api     # un seul
make down           # arrêt (les volumes sont conservés)
make help           # toutes les cibles
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

Les tags publiés par la CI des deux dépôts : `dev` suit `main`, `latest` suit le
dernier tag git, et les tags semver (`1`, `1.2`, `1.2.3`) permettent
d'épingler. **En production, épinglez une version** — `latest` rend les
rollbacks pénibles.

## Mise à jour

```sh
make deploy    # docker compose pull && up -d --remove-orphans && ps
```

Les migrations Alembic sont appliquées automatiquement au démarrage de l'API
(`command.upgrade(…, "head")` dans son `lifespan`).

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

Après toute modification :

```sh
make nginx-reload    # vérifie la syntaxe puis recharge sans couper les connexions
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
   make nginx-reload
   ```

4. Programmer le renouvellement (`certbot renew` puis `make nginx-reload`) dans
   une crontab de l'hôte.

> Si la stack tourne derrière un proxy qui gère déjà le TLS (Traefik, Caddy,
> load balancer d'hébergeur), gardez le vhost HTTP tel quel et ne publiez que
> `HTTP_PORT`.

## Sauvegardes

Le service `backup` produit une copie cohérente et compressée de la base dans
`./backups`, toutes les `BACKUP_INTERVAL` secondes, avec vérification
d'intégrité et rotation.

```sh
make backup     # sauvegarde immédiate
make backups    # liste les archives
```

**[`docs/BACKUP.md`](docs/BACKUP.md)** détaille les stratégies possibles
(snapshots `sqlite3 .backup`, réplication continue Litestream, sauvegarde de
volume, snapshots hébergeur, `pg_dump`/pgBackRest si migration PostgreSQL),
la procédure de restauration, et ce qui compte plus que le choix de l'outil :
hors-site, chiffrement, supervision et tests de restauration.

## Développement local

Ce dépôt déploie les **images publiées**. Pour travailler sur le code, utilisez
les `docker-compose.yml` de chaque dépôt applicatif, qui montent les sources et
activent le rechargement à chaud.
