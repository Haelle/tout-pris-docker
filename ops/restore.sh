#!/bin/sh
# Restaure une sauvegarde dans la base de Tout Pris.
#
#   sudo /srv/tout-pris/ops/restore.sh /srv/tout-pris/backups/tout_pris.sqlite.gz-20260817
#
# Arrête l'API, vérifie l'archive AVANT d'écraser quoi que ce soit, met la base
# courante de côté, puis relance l'API.
#
# Dépendance : le paquet sqlite3.

set -eu

DIR=/srv/tout-pris
DB="$DIR/data/tout_pris.db"

# uid/gid non-root de l'image tout-pris-back : sans ce chown, l'API redémarre
# sur une base qu'elle ne peut pas écrire.
DB_UID=999
DB_GID=999

ARCHIVE="${1:-}"

if [ -z "$ARCHIVE" ]; then
    echo "usage: $0 <archive>" >&2
    echo "archives disponibles :" >&2
    ls -1 "$DIR/backups" >&2 2>/dev/null || echo "  (aucune)" >&2
    exit 64
fi
[ -f "$ARCHIVE" ] || { echo "$ARCHIVE introuvable" >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo "à lancer en root : la base doit être chownée" >&2; exit 1; }

work=$(mktemp)
trap 'rm -f "$work"' EXIT

# logrotate produit tout_pris.sqlite.gz-20260817 : le .gz n'est pas forcément
# la dernière extension.
case "$ARCHIVE" in
    *.gz*) gzip -dc "$ARCHIVE" > "$work" ;;
    *)     cp "$ARCHIVE" "$work" ;;
esac

# Vérification avant toute écriture : une restauration qui échoue après avoir
# écrasé la base en place est une double panne.
check=$(sqlite3 "$work" 'PRAGMA integrity_check;' 2>&1 || true)
[ "$check" = "ok" ] || { echo "archive inutilisable : $check" >&2; exit 1; }
echo "archive valide"

docker compose -f "$DIR/compose.yaml" stop api

# Même une base qu'on croit perdue peut contenir des écritures plus récentes
# que l'archive. Ce nom ne correspond pas au motif de logrotate : cette copie
# ne sera jamais purgée automatiquement.
if [ -f "$DB" ]; then
    safety="$DIR/backups/avant-restauration-$(date -u '+%Y%m%dT%H%M%SZ').sqlite"
    if sqlite3 "$DB" ".backup '$safety'" 2>/dev/null && gzip -9 "$safety"; then
        echo "base courante sauvegardée dans $safety.gz"
    else
        rm -f "$safety"
        cp -a "$DB"* "$DIR/backups/" 2>/dev/null || true
        echo "base courante illisible, copie brute des fichiers" >&2
    fi
fi

# Les -wal/-shm résiduels appartiennent à l'ancienne base : les laisser ferait
# rejouer par SQLite un journal ne correspondant plus au fichier restauré.
rm -f "$DB" "$DB-wal" "$DB-shm"
cp "$work" "$DB"
chown "$DB_UID:$DB_GID" "$DB"
chmod 644 "$DB"

docker compose -f "$DIR/compose.yaml" start api

echo "restauration OK depuis $ARCHIVE"
