#!/usr/bin/env bash
# Backup quotidien de la DB SQLite d'arcadepipe (volume "backend_data"), lancé par
# arcadepipe-backup.timer.
#
# set -euo pipefail : un échec fait passer le service systemd en "failed" (trace
# dans journalctl) au lieu de laisser croire qu'un backup a été pris.
set -euo pipefail

# Destination isolée ici : un stockage distant s'ajoutera EN PLUS (ex. `rclone sync
# "$BACKUP_DEST" remote:bucket` après la rétention), le disque local restant un
# tampon. Non implémenté (voir backup/README.md).
BACKUP_DEST="/var/backups/arcadepipe"

VOLUME="backend_data"
IMAGE="arcadepipe-backup-tool"
DB_NAME="arcadepipe.db"
TIMESTAMP="$(date +%Y-%m-%d_%H%M)"
BACKUP_FILE="arcadepipe_${TIMESTAMP}.db"

DAILY_DIR="$BACKUP_DEST/daily"
WEEKLY_DIR="$BACKUP_DEST/weekly"
mkdir -p "$DAILY_DIR" "$WEEKLY_DIR"

echo "[backup] Démarrage $(date -Iseconds)"

# ".backup" (API de backup officielle de SQLite) copie une base VIVANTE de façon
# cohérente, y compris en mode WAL — jamais un `cp` du .db, qui pourrait capturer
# un état à cheval sur le -wal.
# Pas de montage ":ro" : testé, sqlite3 échoue alors avec "unable to open database
# file", même en lecture (il doit pouvoir créer ses fichiers de verrou).
docker run --rm \
  -v "${VOLUME}:/source" \
  -v "${DAILY_DIR}:/backup" \
  "$IMAGE" \
  sqlite3 "/source/${DB_NAME}" ".backup '/backup/${BACKUP_FILE}'"

BACKUP_PATH="${DAILY_DIR}/${BACKUP_FILE}"

# Vérification immédiate : un `.backup` d'une base corrompue produit un backup tout
# aussi corrompu, sans erreur — on ne veut pas le découvrir le jour d'une restauration.
if [ ! -s "$BACKUP_PATH" ]; then
  echo "[backup] ERREUR : fichier de backup vide ou absent ($BACKUP_PATH)" >&2
  exit 1
fi

INTEGRITY="$(docker run --rm -v "${DAILY_DIR}:/backup" "$IMAGE" \
  sqlite3 "/backup/${BACKUP_FILE}" "PRAGMA integrity_check;")"

if [ "$INTEGRITY" != "ok" ]; then
  echo "[backup] ERREUR : integrity_check a échoué sur $BACKUP_PATH : $INTEGRITY" >&2
  exit 1
fi

echo "[backup] OK : $BACKUP_PATH ($(du -h "$BACKUP_PATH" | cut -f1), integrity_check=ok)"

# Le dimanche (date +%u == 7), le backup du jour, déjà validé, est aussi copié dans weekly/.
if [ "$(date +%u)" = "7" ]; then
  cp "$BACKUP_PATH" "${WEEKLY_DIR}/${BACKUP_FILE}"
  echo "[backup] Copié aussi dans weekly/ (dimanche)"
fi

# Rétention : garder les N plus récents par dossier. `xargs -r` : sans lui, un dossier
# sans rien à purger lancerait `rm` sans argument et ferait échouer le script.
purge_old() {
  local dir="$1"
  local keep="$2"
  ls -t "$dir" | tail -n "+$((keep + 1))" | xargs -r -I{} rm -- "$dir/{}"
}
purge_old "$DAILY_DIR" 7
purge_old "$WEEKLY_DIR" 4

echo "[backup] Terminé $(date -Iseconds) — $(ls "$DAILY_DIR" | wc -l) daily, $(ls "$WEEKLY_DIR" | wc -l) weekly"
