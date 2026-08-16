# Sauvegarder la base de Tout Pris

## Ce qu'on sauvegarde exactement

`tout-pris-back` stocke tout dans **SQLite**, en un fichier unique
(`/data/tout_pris.db` dans le volume `db_data`), ouvert en **mode WAL**
(`PRAGMA journal_mode=WAL`, posé à chaque connexion dans `app/database.py`).

Deux conséquences pratiques :

- il n'y a **pas de serveur de base de données** à sauvegarder, juste un
  fichier — c'est le cas le plus simple qui soit ;
- ce fichier est accompagné d'un `-wal` et d'un `-shm`. Les transactions
  récentes vivent dans le `-wal` tant qu'aucun *checkpoint* n'a eu lieu.

## Ce qu'il ne faut pas faire

| Méthode | Pourquoi c'est risqué |
| --- | --- |
| `cp tout_pris.db sauvegarde.db` | Copie non atomique : le fichier peut être capturé au milieu d'une écriture, et le `-wal` n'est pas copié avec. Résultat : base corrompue ou transactions perdues, sans erreur au moment de la copie. |
| `docker cp` / `tar` sur le volume à chaud | Même problème, aggravé par la lenteur de `tar` : plus la copie dure, plus la fenêtre d'incohérence est large. |
| `rsync` du fichier pendant que l'API tourne | Idem. `rsync` n'a aucune notion de transaction. |
| Sauvegarder seulement `.db` sans `-wal` | Perte silencieuse de toutes les transactions non checkpointées. |

La règle : **une sauvegarde SQLite passe par SQLite**, pas par le système de
fichiers. Sauf si l'on arrête l'écrivain, ou si l'on prend un instantané
atomique au niveau du système de fichiers (voir option D).

## Les options

### A. Snapshots périodiques via `sqlite3 .backup` — *implémenté ici*

C'est ce que fait le service `backup` de `compose.yaml`
([`backup/backup.sh`](../backup/backup.sh)).

```sh
sqlite3 /data/tout_pris.db ".backup '/backups/tout_pris-20260816T031500Z.sqlite'"
```

`.backup` utilise l'**API de sauvegarde en ligne** de SQLite : elle produit une
copie cohérente pendant que l'API continue d'écrire, WAL inclus. Le script y
ajoute ce qui fait la différence entre « un script de backup » et « des
sauvegardes fiables » :

- un `PRAGMA integrity_check` sur la copie **avant** de la garder — une archive
  corrompue découverte le jour de la restauration ne sert à rien ;
- une écriture en `.tmp` renommée seulement en cas de succès, donc jamais
  d'archive tronquée dans le dossier ;
- compression `gzip -9` (une base SQLite se compresse très bien) ;
- rotation sur les `BACKUP_RETENTION` dernières archives ;
- un ping optionnel vers un *dead man's switch* (`HEALTHCHECK_URL`).

> Alternative à `.backup` : `VACUUM INTO '/backups/…'`, qui produit en plus une
> copie défragmentée et plus compacte. Légèrement plus coûteux en I/O, même
> garantie de cohérence. Pour une base de cette taille, les deux conviennent.

**Bien** : simple, sans dépendance externe, restauration triviale.
**Limite** : le RPO est l'intervalle. Avec `BACKUP_INTERVAL=86400`, une panne
peut coûter jusqu'à 24 h d'écritures.

### B. Réplication continue avec Litestream — *recommandé dès qu'il y a des vrais utilisateurs*

[Litestream](https://litestream.io) suit le WAL de SQLite et réplique en
continu vers un stockage objet (S3, Backblaze B2, MinIO…). RPO de l'ordre de
la seconde, restauration à un instant donné (PITR), et le hors-site est gratuit
par construction.

Surcouche à ajouter, par exemple dans un `compose.litestream.yaml` :

```yaml
services:
  litestream:
    image: litestream/litestream:0.3
    restart: unless-stopped
    command: replicate
    volumes:
      - db_data:/data                              # accès en écriture : shadow WAL
      - ./litestream.yml:/etc/litestream.yml:ro
    environment:
      LITESTREAM_ACCESS_KEY_ID: ${S3_ACCESS_KEY}
      LITESTREAM_SECRET_ACCESS_KEY: ${S3_SECRET_KEY}
    depends_on:
      api:
        condition: service_healthy
    networks: [toutpris]
```

```yaml
# litestream.yml
dbs:
  - path: /data/tout_pris.db
    replicas:
      - type: s3
        bucket: tout-pris-backups
        path: tout_pris
        region: eu-west-3
        retention: 720h          # 30 jours
        snapshot-interval: 24h
```

Restauration :

```sh
docker compose run --rm litestream restore -o /data/tout_pris.db s3://tout-pris-backups/tout_pris
```

**Bien** : RPO ~1 s, hors-site natif, PITR.
**Limite** : un composant de plus, et un seul écrivain autorisé sur la base
(ce qui est déjà le cas ici — un unique conteneur `api`).

### C. Sauvegarde du volume avec `offen/docker-volume-backup`

Une brique générique qui archive un volume Docker entier, avec chiffrement
GPG, rotation, et envoi vers S3/WebDAV/SSH. Elle sait exécuter une commande
avant l'archivage — indispensable ici pour produire d'abord un `.backup`
cohérent, ou arrêter momentanément le service `api`.

**Bien** : couvre tout le volume, pas seulement la base ; hors-site et
chiffrement intégrés.
**Limite** : sans le *hook* de pré-commande, on retombe exactement sur le
problème du tableau « ce qu'il ne faut pas faire ».

### D. Instantanés au niveau du système de fichiers ou de l'hébergeur

Snapshots LVM/ZFS/Btrfs, ou snapshots de disque chez l'hébergeur (Hetzner,
Scaleway, OVH…). L'instantané étant atomique, SQLite retrouve une base dans un
état *crash-consistent* : il rejoue le WAL au démarrage, exactement comme après
une coupure de courant. C'est correct, et SQLite est conçu pour ça.

**Bien** : coût quasi nul, couvre toute la machine, aucune configuration.
**Limite** : granularité grossière (souvent quotidienne), restauration
« tout ou rien », et l'instantané vit chez le même hébergeur que le serveur —
ce n'est pas du hors-site.

À utiliser **en complément**, jamais seul.

### E. Si la base migre vers PostgreSQL

Voir [`compose.postgres.yaml`](../compose.postgres.yaml) pour l'état actuel du
sujet côté code. Une fois la bascule faite :

- **`pg_dump --format=custom`** — sauvegarde logique, restaurable table par
  table avec `pg_restore`, portable entre versions majeures. C'est ce que fait
  déjà `backup.sh` avec `BACKUP_ENGINE=postgres`. Suffisant jusqu'à quelques
  dizaines de Go.
- **`pg_basebackup` + archivage des WAL**, ou
  **[pgBackRest](https://pgbackrest.org)** / **[Barman](https://pgbarman.org)** —
  sauvegardes physiques incrémentales avec PITR. C'est le pendant de Litestream
  pour PostgreSQL, et l'outillage de référence en production.
- **Base managée** (RDS, Scaleway, Neon, Supabase…) — le PITR est fourni. La
  sauvegarde reste votre responsabilité : un `pg_dump` hebdomadaire exporté
  hors du fournisseur vous protège de la perte du compte, que le PITR ne
  couvre pas.

## Tableau de synthèse

| Option | RPO | Restauration | Hors-site | Complexité |
| --- | --- | --- | --- | --- |
| A. `.backup` périodique *(ici)* | intervalle (24 h par défaut) | copier le fichier | à ajouter | ★☆☆ |
| B. Litestream | ~1 s | `litestream restore` | natif | ★★☆ |
| C. `docker-volume-backup` | intervalle | extraire l'archive | natif | ★★☆ |
| D. Snapshots hébergeur | 6–24 h | restaurer le disque | non | ★☆☆ |
| E. pgBackRest *(si PostgreSQL)* | ~1 min | PITR | natif | ★★★ |

Combinaison recommandée pour ce projet : **A + un envoi hors-site** aujourd'hui,
**B** dès que perdre 24 h d'écritures devient inacceptable, **D** en filet de
sécurité systématique.

## Restaurer

### SQLite

```sh
# 1. Choisir l'archive
ls -lh backups/

# 2. Arrêter l'API (personne ne doit écrire pendant l'opération)
docker compose stop api backup

# 3. Décompresser
gunzip -k backups/tout_pris-20260816T031500Z.sqlite.gz

# 4. Remplacer le fichier dans le volume, et supprimer les -wal/-shm résiduels
#    (les garder ferait rejouer un WAL qui ne correspond plus à cette base)
docker compose run --rm -v ./backups:/backups --entrypoint sh backup -c '
  rm -f /data/tout_pris.db /data/tout_pris.db-wal /data/tout_pris.db-shm &&
  cp /backups/tout_pris-20260816T031500Z.sqlite /data/tout_pris.db &&
  chown 999:999 /data/tout_pris.db          # uid non-root de l'\''image de prod
'

# 5. Relancer
docker compose up -d
docker compose logs -f api
```

Les migrations Alembic sont rejouées au démarrage de l'API (`command.upgrade`
dans le `lifespan`) : restaurer une base plus ancienne que le code déployé est
donc géré automatiquement.

### PostgreSQL

```sh
docker compose stop api
docker compose exec -T db pg_restore \
  --username=tout_pris --dbname=tout_pris --clean --if-exists \
  < backups/tout_pris-20260816T031500Z.dump
docker compose up -d api
```

## Ce qui compte plus que le choix de l'outil

1. **Le hors-site.** Une sauvegarde sur le même disque que la base ne protège
   que de l'erreur humaine, pas de la perte du serveur. Règle 3-2-1 :
   3 copies, 2 supports, 1 hors-site. Le plus simple ici :

   ```sh
   # dans une crontab de l'hôte
   rclone sync /srv/tout-pris/backups b2:tout-pris-backups --transfers 4
   ```

   ou [restic](https://restic.net) si vous voulez la déduplication et le
   chiffrement en une seule commande.

2. **Le chiffrement**, si les sauvegardes quittent votre infrastructure.
   `age` est le plus simple : `age -r <clé publique> < archive > archive.age`.
   Gardez la clé privée **ailleurs** que sur le serveur sauvegardé.

3. **La supervision.** Une sauvegarde qui échoue en silence est pire que pas de
   sauvegarde : elle donne un faux sentiment de sécurité. `HEALTHCHECK_URL`
   dans `.env` fait pinguer un service type
   [healthchecks.io](https://healthchecks.io) après chaque succès ; l'absence
   de ping déclenche l'alerte.

4. **Les tests de restauration.** C'est l'étape que tout le monde saute. Une
   restauration à blanc par trimestre, chronométrée, sur une stack jetable :

   ```sh
   docker compose -p toutpris-restore-test up -d
   ```

   C'est le seul moyen de savoir que vos archives sont exploitables, et de
   connaître votre RTO réel.

5. **La rétention.** `BACKUP_RETENTION=14` garde 14 jours. Une corruption
   logique découverte au bout de trois semaines n'est donc pas récupérable.
   Un schéma *grand-père/père/fils* (7 quotidiennes + 4 hebdomadaires +
   12 mensuelles) coûte très peu en volume ici et couvre ce cas.
