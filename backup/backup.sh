#!/bin/sh
# Sauvegarde de la base SQLite de Tout Pris.
#
# Lancé par tout-pris-backup.timer. Écrit toujours le même fichier : la
# rétention est laissée à logrotate (voir logrotate-tout-pris).
#
# Dépendance : le paquet sqlite3.

set -eu

DB=/srv/tout-pris/data/tout_pris.db
DEST=/var/backups/tout-pris/tout_pris.sqlite.gz

[ -f "$DB" ] || { echo "base introuvable : $DB" >&2; exit 1; }
mkdir -p "$(dirname "$DEST")"

tmp="$DEST.tmp"
trap 'rm -f "$tmp" "$tmp.db"' EXIT

# .backup passe par l'API de sauvegarde en ligne de SQLite : copie cohérente
# pendant que l'API écrit, WAL compris. Un `cp` du fichier ne garantit rien,
# les dernières transactions vivant dans le -wal.
sqlite3 "$DB" ".backup '$tmp.db'"

check=$(sqlite3 "$tmp.db" 'PRAGMA integrity_check;')
[ "$check" = "ok" ] || { echo "sauvegarde corrompue : $check" >&2; exit 1; }

gzip -9 -c "$tmp.db" > "$tmp"
# Renommage final : la destination n'est jamais laissée tronquée, et la
# sauvegarde précédente survit si l'une des étapes ci-dessus échoue.
mv "$tmp" "$DEST"

echo "sauvegarde OK : $DEST ($(du -h "$DEST" | cut -f1))"
