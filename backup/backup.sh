#!/bin/sh
# Sauvegardes périodiques de la base SQLite de Tout Pris.
#
#   backup.sh once   -> une sauvegarde puis sortie (code de retour utilisable)
#   backup.sh loop   -> une sauvegarde toutes les $BACKUP_INTERVAL secondes
#
# Variables d'environnement (valeurs par défaut entre parenthèses) :
#   BACKUP_DIR        dossier de destination        (/backups)
#   BACKUP_INTERVAL   secondes entre deux passes    (86400)
#   BACKUP_RETENTION  nombre d'archives conservées  (14)
#   SQLITE_PATH       chemin du fichier .db         (/data/tout_pris.db)
#   HEALTHCHECK_URL   URL pingée après un succès    (vide = désactivé)

set -eu

BACKUP_DIR="${BACKUP_DIR:-/backups}"
BACKUP_INTERVAL="${BACKUP_INTERVAL:-86400}"
BACKUP_RETENTION="${BACKUP_RETENTION:-14}"
SQLITE_PATH="${SQLITE_PATH:-/data/tout_pris.db}"
HEALTHCHECK_URL="${HEALTHCHECK_URL:-}"

log() { echo "[backup] $(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"; }

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
    # Renommage final : le dossier ne contient donc jamais d'archive tronquée.
    mv "${dest}.tmp.gz" "${dest}.gz"
    log "OK $(basename "${dest}.gz") ($(du -h "${dest}.gz" | cut -f1))"
}

# Conserve les $BACKUP_RETENTION archives les plus récentes.
prune() {
    # shellcheck disable=SC2012 # ls -t suffit : nos noms n'ont ni espace ni retour ligne
    ls -1t "$BACKUP_DIR"/tout_pris-*.sqlite.gz 2>/dev/null \
        | tail -n "+$((BACKUP_RETENTION + 1))" \
        | while read -r old; do
              log "rotation: suppression de $(basename "$old")"
              rm -f "$old"
          done
}

run_once() {
    mkdir -p "$BACKUP_DIR"
    backup_sqlite "$BACKUP_DIR/tout_pris-$(date -u '+%Y%m%dT%H%M%SZ').sqlite"
    prune

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
        log "démarrage — intervalle=${BACKUP_INTERVAL}s rétention=$BACKUP_RETENTION"
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
