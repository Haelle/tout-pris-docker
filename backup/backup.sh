#!/bin/sh
# Sauvegardes périodiques de la base de Tout Pris.
#
#   backup.sh once   -> une sauvegarde puis sortie (code de retour utilisable)
#   backup.sh loop   -> une sauvegarde toutes les $BACKUP_INTERVAL secondes
#
# Variables d'environnement (valeurs par défaut entre parenthèses) :
#   BACKUP_ENGINE     sqlite | postgres            (sqlite)
#   BACKUP_DIR        dossier de destination        (/backups)
#   BACKUP_INTERVAL   secondes entre deux passes    (86400)
#   BACKUP_RETENTION  nombre d'archives conservées  (14)
#   SQLITE_PATH       chemin du fichier .db         (/data/tout_pris.db)
#   POSTGRES_HOST / _PORT / _DB / _USER / _PASSWORD
#   HEALTHCHECK_URL   URL pingée après un succès    (vide = désactivé)

set -eu

BACKUP_ENGINE="${BACKUP_ENGINE:-sqlite}"
BACKUP_DIR="${BACKUP_DIR:-/backups}"
BACKUP_INTERVAL="${BACKUP_INTERVAL:-86400}"
BACKUP_RETENTION="${BACKUP_RETENTION:-14}"
SQLITE_PATH="${SQLITE_PATH:-/data/tout_pris.db}"
POSTGRES_HOST="${POSTGRES_HOST:-db}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_DB="${POSTGRES_DB:-tout_pris}"
POSTGRES_USER="${POSTGRES_USER:-tout_pris}"
HEALTHCHECK_URL="${HEALTHCHECK_URL:-}"

log() { echo "[backup] $(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"; }

# --- SQLite ------------------------------------------------------------------
# `.backup` passe par l'API de sauvegarde en ligne de SQLite : elle produit un
# fichier cohérent pendant que l'API continue d'écrire, y compris en mode WAL.
# Copier le .db à la main (cp / tar / docker cp) ne donne aucune garantie :
# les dernières transactions vivent dans le -wal, qui n'est pas copié
# atomiquement avec le fichier principal.
backup_sqlite() {
    dest="$1"

    [ -f "$SQLITE_PATH" ] || { log "ERREUR: $SQLITE_PATH introuvable"; return 1; }

    sqlite3 "$SQLITE_PATH" ".backup '${dest}.tmp'"

    # Vérification immédiate : une archive corrompue détectée le jour de la
    # restauration ne sert à rien.
    check="$(sqlite3 "${dest}.tmp" 'PRAGMA integrity_check;' 2>&1 || true)"
    if [ "$check" != "ok" ]; then
        log "ERREUR: integrity_check a répondu « $check »"
        rm -f "${dest}.tmp"
        return 1
    fi

    gzip -9 "${dest}.tmp"
    mv "${dest}.tmp.gz" "${dest}.gz"
    log "OK $(basename "${dest}.gz") ($(du -h "${dest}.gz" | cut -f1))"
}

# --- PostgreSQL --------------------------------------------------------------
# Format « custom » : compressé, et restaurable table par table avec pg_restore.
backup_postgres() {
    dest="$1"

    PGPASSWORD="${POSTGRES_PASSWORD:-}" pg_dump \
        --host="$POSTGRES_HOST" \
        --port="$POSTGRES_PORT" \
        --username="$POSTGRES_USER" \
        --dbname="$POSTGRES_DB" \
        --format=custom \
        --compress=9 \
        --file="${dest}.tmp"

    PGPASSWORD="${POSTGRES_PASSWORD:-}" pg_restore --list "${dest}.tmp" > /dev/null

    mv "${dest}.tmp" "$dest"
    log "OK $(basename "$dest") ($(du -h "$dest" | cut -f1))"
}

# --- Rotation ----------------------------------------------------------------
# Conserve les $BACKUP_RETENTION archives les plus récentes.
prune() {
    pattern="$1"
    # shellcheck disable=SC2012 # ls -t est suffisant : nos noms n'ont ni espace ni retour ligne
    ls -1t "$BACKUP_DIR"/$pattern 2>/dev/null \
        | tail -n "+$((BACKUP_RETENTION + 1))" \
        | while read -r old; do
              log "rotation: suppression de $(basename "$old")"
              rm -f "$old"
          done
}

run_once() {
    mkdir -p "$BACKUP_DIR"
    stamp="$(date -u '+%Y%m%dT%H%M%SZ')"

    case "$BACKUP_ENGINE" in
        sqlite)
            backup_sqlite "$BACKUP_DIR/tout_pris-$stamp.sqlite"
            prune 'tout_pris-*.sqlite.gz'
            ;;
        postgres)
            backup_postgres "$BACKUP_DIR/tout_pris-$stamp.dump"
            prune 'tout_pris-*.dump'
            ;;
        *)
            log "ERREUR: BACKUP_ENGINE inconnu « $BACKUP_ENGINE » (sqlite|postgres)"
            return 2
            ;;
    esac

    # Dead man's switch : si le ping n'arrive pas, le service de supervision
    # (healthchecks.io, Cronitor…) alerte. Sans ça, on découvre l'absence de
    # sauvegardes le jour où on en a besoin.
    if [ -n "$HEALTHCHECK_URL" ]; then
        curl -fsS -m 10 --retry 3 "$HEALTHCHECK_URL" > /dev/null \
            || log "AVERTISSEMENT: ping de supervision échoué"
    fi
}

case "${1:-loop}" in
    once)
        run_once
        ;;
    loop)
        log "démarrage — moteur=$BACKUP_ENGINE intervalle=${BACKUP_INTERVAL}s rétention=$BACKUP_RETENTION"
        while true; do
            run_once || log "ERREUR: la sauvegarde a échoué, nouvelle tentative dans ${BACKUP_INTERVAL}s"
            sleep "$BACKUP_INTERVAL"
        done
        ;;
    *)
        echo "usage: backup.sh [once|loop]" >&2
        exit 64
        ;;
esac
