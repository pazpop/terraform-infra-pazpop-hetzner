#!/usr/bin/env bash
# Backup quotidien de la DB SQLite d'arcadepipe (volume "backend_data"), lancé par
# arcadepipe-backup.timer.
#
# set -euo pipefail : un échec fait passer le service systemd en "failed" (trace
# dans journalctl) au lieu de laisser croire qu'un backup a été pris.
set -euo pipefail
source "$(dirname "$0")/common.sh"

# Destination locale ; un stockage distant s'ajoutera en plus (voir backup/README.md).
# test-backup-restore.sh en donne une autre : son backup, qui contient un score
# de test, ne se mêle pas aux vrais et ne compte pas dans leur rétention.
BACKUP_DEST="${BACKUP_DEST:-/var/backups/arcadepipe}"

VOLUME="backend_data"
DB_NAME="arcadepipe.db"
BACKUP_FILE="arcadepipe_$(date +%Y-%m-%d_%H%M).db"

DAILY_DIR="$BACKUP_DEST/daily"
WEEKLY_DIR="$BACKUP_DEST/weekly"
mkdir -p "$DAILY_DIR" "$WEEKLY_DIR"

echo "[backup] Démarrage $(date -Iseconds)"

# ".backup" (API de backup officielle de SQLite) copie une base VIVANTE de façon
# cohérente, y compris en mode WAL — jamais un `cp` du .db, qui pourrait capturer
# un état à cheval sur le -wal.
# Pas de montage ":ro" : sqlite3 échoue alors avec "unable to open database file",
# même en lecture (il doit pouvoir créer ses fichiers de verrou).
# -readonly : si la base manque (volume vide), sqlite3 échoue au lieu d'en créer
# une vide, qui donnerait un backup « réussi » sans aucun score.
# La copie est écrite sous un nom provisoire (un fichier caché, que la rotation
# ignore) et ne prend son nom définitif qu'une fois vérifiée : un échec ne laisse
# jamais dans daily/ un fichier vide ou corrompu qui passerait pour un backup.
PARTIAL=".en-cours.db"
BACKUP_PATH="${DAILY_DIR}/${BACKUP_FILE}"
rm -f "${DAILY_DIR}/${PARTIAL}"
docker run --rm \
  -v "${VOLUME}:/source" \
  -v "${DAILY_DIR}:/backup" \
  "$IMAGE" \
  sqlite3 -readonly "/source/${DB_NAME}" ".backup '/backup/${PARTIAL}'"

# Vérification immédiate : un `.backup` d'une base corrompue produit un backup tout
# aussi corrompu, sans erreur.
if [ ! -s "${DAILY_DIR}/${PARTIAL}" ]; then
  echo "[backup] ERREUR : copie vide ou absente" >&2
  exit 1
fi

INTEGRITY="$(docker run --rm -v "${DAILY_DIR}:/backup" "$IMAGE" \
  sqlite3 "/backup/${PARTIAL}" "PRAGMA integrity_check;")"

if [ "$INTEGRITY" != "ok" ]; then
  echo "[backup] ERREUR : integrity_check a échoué : $INTEGRITY" >&2
  exit 1
fi
mv "${DAILY_DIR}/${PARTIAL}" "$BACKUP_PATH"

echo "[backup] OK : $BACKUP_PATH ($(du -h "$BACKUP_PATH" | cut -f1), integrity_check=ok)"

rotation "$BACKUP_PATH" "[backup]"
