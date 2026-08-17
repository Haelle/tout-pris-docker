# tout-pris-docker

Déploiement de la stack **Tout Pris** : le backend
[`tout-pris-back`](https://github.com/Haelle/tout-pris-back) (FastAPI) et le
front [`tout-pris-front`](https://github.com/Haelle/tout-pris-front) (SvelteKit
statique).

Ce dépôt ne contient pas de code applicatif : uniquement le `compose.yaml`, la
configuration nginx à installer sur l'hôte, et les scripts de sauvegarde.

## Architecture

```
  internet ──▶ nginx (hôte, 80/443)
                 ├── /      ──▶ 127.0.0.1:8080  conteneur front (SPA)
                 └── /api/  ──▶ 127.0.0.1:8000  conteneur api (FastAPI)
                                                        │
                                                        ▼
                                                  ./data/tout_pris.db
                                                        ▲
                          systemd timer ──▶ ops/backup.sh ──▶ ./backups/
```

Deux conteneurs seulement. **Le reverse proxy est le nginx de l'hôte**, pas un
conteneur : le TLS, les autres vhosts et les certificats restent gérés là où ils
le sont déjà. Les deux ports sont publiés sur la loopback, donc inaccessibles
depuis l'extérieur autrement que par nginx.

Le front et l'API sont servis **depuis la même origine** : le SPA appelle
`/api/<chemin>`, nginx retire le préfixe et route vers FastAPI qui expose
`<chemin>` à sa racine. Pas de CORS, pas d'URL d'API à configurer dans le front.

La base est un **SQLite** — un fichier dans `./data`, pas de serveur de base.
C'est un bind mount et non un volume nommé, pour que les scripts de l'hôte
puissent le lire directement.

## Installation

La suite suppose le dépôt déployé dans `/srv/tout-pris` ; si vous le mettez
ailleurs, ajustez le chemin en tête de `ops/backup.sh`, `ops/restore.sh`,
`ops/tout-pris-backup.service` et `ops/logrotate-tout-pris`.

```sh
sudo git clone https://github.com/Haelle/tout-pris-docker /srv/tout-pris
cd /srv/tout-pris

# Le conteneur api tourne en 999:999 (utilisateur non-root de son image) et
# doit pouvoir écrire dans le bind mount.
sudo mkdir -p data backups
sudo chown 999:999 data

sudo docker compose up -d
sudo docker compose ps
```

### nginx

```sh
sudo cp nginx/tout-pris.conf /etc/nginx/sites-available/tout-pris
sudo sed -i 's/tout-pris.example.com/VOTRE-DOMAINE/' /etc/nginx/sites-available/tout-pris
sudo ln -s /etc/nginx/sites-available/tout-pris /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

Pour le HTTPS, `certbot` écrit lui-même le bloc 443 et la redirection :

```sh
sudo certbot --nginx -d VOTRE-DOMAINE
```

### Sauvegardes

Trois fichiers, un par responsabilité : le script sauvegarde, le timer
déclenche, logrotate gère la rétention.

```sh
sudo apt install sqlite3

sudo cp ops/tout-pris-backup.service ops/tout-pris-backup.timer /etc/systemd/system/
sudo cp ops/logrotate-tout-pris /etc/logrotate.d/tout-pris

sudo systemctl daemon-reload
sudo systemctl enable --now tout-pris-backup.timer
```

Vérifier :

```sh
sudo systemctl start tout-pris-backup.service   # déclenche une sauvegarde
sudo systemctl status tout-pris-backup.service
sudo systemctl list-timers tout-pris-backup.timer
ls -lh /srv/tout-pris/backups/
sudo logrotate -d /etc/logrotate.d/tout-pris    # simulation, sans rien écrire
```

## Fonctionnement des sauvegardes

`ops/backup.sh` produit `backups/tout_pris.sqlite.gz` — **toujours le même
nom**. C'est logrotate qui le date et décide combien de copies conserver
(`rotate 14` par défaut), plutôt qu'une logique de rétention dans le script.

Le script utilise `sqlite3 .backup`, c'est-à-dire l'**API de sauvegarde en
ligne** de SQLite : elle produit un fichier cohérent pendant que l'API continue
d'écrire. Un `cp` du `.db` ne garantit rien — les dernières transactions vivent
dans le `-wal`, qui n'est pas copié atomiquement avec le fichier principal, et
rien ne signale le problème au moment de la copie. Chaque sauvegarde est relue
avec `PRAGMA integrity_check` et n'est renommée sous son nom définitif qu'en cas
de succès : la sauvegarde précédente survit donc à un échec.

Le timer tourne à 03:00 et `logrotate.timer` vers 00:00. L'ordre compte : la
rotation date le fichier de la veille avant que celui du jour ne soit écrit. Si
vous changez l'heure du timer, gardez-la après celle de logrotate.

Deux points restent à votre charge :

- **Le hors-site.** Les sauvegardes sont sur le même disque que la base, ce qui
  ne protège que de l'erreur humaine. Un `rclone`/`restic` vers un stockage
  distant, dans un second timer, est le complément minimal.
- **L'alerting.** `OnFailure=` dans `tout-pris-backup.service` est le point
  d'accroche prévu : sans lui, une sauvegarde qui échoue le fait en silence.

## Restaurer la base

```sh
ls -lh /srv/tout-pris/backups/
sudo /srv/tout-pris/ops/restore.sh /srv/tout-pris/backups/tout_pris.sqlite.gz-20260817
```

Le script enchaîne : décompression dans un fichier de travail →
`PRAGMA integrity_check` et **arrêt immédiat si l'archive est mauvaise, avant
d'avoir touché à la base** → arrêt du conteneur `api` → mise de côté de la base
courante dans `backups/avant-restauration-<horodatage>.sqlite.gz`, car même une
base qu'on croit perdue peut contenir des écritures plus récentes que l'archive
→ suppression des `-wal`/`-shm` résiduels, qui feraient rejouer à SQLite un
journal ne correspondant plus au fichier restauré → installation de l'archive et
`chown 999:999` → redémarrage de l'`api`.

Sans argument, il liste les archives disponibles. Vérifier ensuite :

```sh
sudo docker compose -f /srv/tout-pris/compose.yaml logs -f api
curl -fsS https://VOTRE-DOMAINE/api/health
```

Restaurer une archive plus ancienne que le code déployé ne pose pas de
problème : l'API applique les migrations Alembic manquantes au démarrage
(`command.upgrade(…, "head")` dans son `lifespan`). L'inverse — une base issue
d'une version *plus récente* du backend — n'est pas géré, Alembic ne sachant pas
redescendre tout seul.

> Testez cette procédure au moins une fois **avant** d'en avoir besoin. C'est le
> seul moyen de savoir que vos archives sont exploitables.

## Mise à jour

```sh
sudo docker compose pull
sudo docker compose up -d
```

Les migrations Alembic sont appliquées automatiquement au démarrage de l'API.

Pour que ce soit automatique, un service `watchtower` est fourni **commenté** en
fin de `compose.yaml` : `api` et `front` portent déjà le label
`com.centurylinklabs.watchtower.enable`, et `WATCHTOWER_LABEL_ENABLE` restreint
Watchtower à eux seuls. Deux points avant de l'activer : le socket Docker donne
au conteneur un accès équivalent à root sur l'hôte, et une nouvelle image du
backend peut embarquer une migration appliquée sans supervision au redémarrage.

## Exploitation

```sh
sudo docker compose ps
sudo docker compose logs -f api
sudo docker compose down
```

La rotation des logs Docker n'est pas configurée ici : elle relève du démon, via
`log-opts` dans `/etc/docker/daemon.json`.

## Développement local

Ce dépôt déploie les **images publiées**. Pour travailler sur le code, utilisez
les `docker-compose.yml` de chaque dépôt applicatif, qui montent les sources et
activent le rechargement à chaud.
