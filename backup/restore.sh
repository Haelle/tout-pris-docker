#!/bin/sh
# Restaure une archive produite par backup.sh dans le volume de la base.
#
# Lancé par le service `restore` du profil `tools` :
#
#   docker compose stop api backup
#   ARCHIVE=tout_pris-20260816T031500Z.sqlite.gz docker compose up restore
#   docker compose up -d
#
# Le script est volontairement défensif : il vérifie l'archive AVANT de
# toucher à la base, et met de côté l'état courant avant de l'écraser.
#
# Variables d'environnement :
#   ARCHIVE      nom du fichier dans $BACKUP_DIR (.gz accepté)  — obligatoire
#   BACKUP_DIR   dossier des archives                            (/backups)
#   SQLITE_PATH  chemin de la base à remplacer     (/data/tout_pris.db)

set -eu

ARCHIVE="${ARCHIVE:-}"
BACKUP_DIR="${BACKUP_DIR:-/backups}"
SQLITE_PATH="${SQLITE_PATH:-/data/tout_pris.db}"

# uid/gid non-root de l'image de production de tout-pris-back : sans ce chown,
# l'API redémarre sur une base qu'elle ne peut pas écrire.
DB_UID=999
DB_GID=999

WORK=/tmp/restore.sqlite

log()  { echo "[restore] $*"; }
fail() { echo "[restore] ÉCHEC: $*" >&2; exit 1; }

# --- 1. Vérifier les paramètres ---------------------------------------------
[ -n "$ARCHIVE" ] || fail "ARCHIVE non défini.
    Usage : ARCHIVE=<fichier> docker compose up restore
    Archives disponibles :
$(ls -1 "$BACKUP_DIR" 2>/dev/null | sed 's/^/      /' || echo '      (aucune)')"

# On n'accepte qu'un nom de fichier, pas un chemin : évite de désigner par
# mégarde un fichier hors du dossier des archives.
case "$ARCHIVE" in
    */*) fail "ARCHIVE doit être un nom de fichier, pas un chemin ($ARCHIVE)" ;;
esac

SOURCE="$BACKUP_DIR/$ARCHIVE"
[ -f "$SOURCE" ] || fail "$SOURCE introuvable"

# --- 2. Décompresser dans un fichier de travail ------------------------------
# On travaille sur une copie : l'archive d'origine reste intacte, y compris si
# la suite échoue.
rm -f "$WORK"
case "$ARCHIVE" in
    *.gz) log "décompression de $ARCHIVE"; gzip -dc "$SOURCE" > "$WORK" ;;
    *)    log "copie de $ARCHIVE";        cp "$SOURCE" "$WORK" ;;
esac

# --- 3. Vérifier l'archive AVANT de toucher à la base ------------------------
# Une restauration qui échoue après avoir écrasé la base est une double panne.
log "vérification de l'intégrité"
check="$(sqlite3 "$WORK" 'PRAGMA integrity_check;' 2>&1 || true)"
[ "$check" = "ok" ] || fail "archive inutilisable, integrity_check a répondu « $check »"

tables="$(sqlite3 "$WORK" "SELECT count(*) FROM sqlite_master WHERE type='table';")"
log "archive valide ($tables tables)"

# --- 4. Mettre de côté l'état courant ----------------------------------------
# Même une base que l'on croit perdue peut contenir des écritures plus récentes
# que l'archive. Le nom choisi ne correspond pas au motif de rotation de
# backup.sh : cette copie ne sera jamais purgée automatiquement.
if [ -f "$SQLITE_PATH" ]; then
    safety="$BACKUP_DIR/avant-restauration-$(date -u '+%Y%m%dT%H%M%SZ').sqlite"
    if sqlite3 "$SQLITE_PATH" ".backup '$safety'" 2>/dev/null; then
        gzip -9 "$safety"
        log "état courant sauvegardé dans $(basename "$safety").gz"
    else
        # Base trop abîmée pour l'API de sauvegarde : on copie les trois
        # fichiers bruts. L'API étant arrêtée, ils forment un ensemble cohérent.
        cp -a "$SQLITE_PATH"* "$BACKUP_DIR/" 2>/dev/null || true
        log "AVERTISSEMENT: base courante illisible, copie brute des fichiers"
    fi
else
    log "aucune base en place, rien à mettre de côté"
fi

# --- 5. Installer l'archive --------------------------------------------------
# Les -wal/-shm résiduels appartiennent à l'ancienne base : les laisser ferait
# rejouer par SQLite un journal qui ne correspond plus au fichier restauré.
log "remplacement de $SQLITE_PATH"
rm -f "$SQLITE_PATH" "$SQLITE_PATH-wal" "$SQLITE_PATH-shm"
cp "$WORK" "$SQLITE_PATH"
chown "$DB_UID:$DB_GID" "$SQLITE_PATH"
chmod 644 "$SQLITE_PATH"
rm -f "$WORK"

log "OK — base restaurée depuis $ARCHIVE"
log "Relancez la stack : docker compose up -d"
