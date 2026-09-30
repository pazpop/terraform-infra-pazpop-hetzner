#!/usr/bin/env bash
# Restaure la DB arcadepipe depuis un backup de backup-arcadepipe-db.sh.
# Usage : ./restore-arcadepipe-db.sh <chemin-du-backup>
# Scripté plutôt que documenté : un incident n'est pas le moment de taper à la
# main. Déroulé humain équivalent : backup/README.md.
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Usage: $0 <chemin-du-fichier-de-backup.db>" >&2
  exit 1
fi

BACKUP_SOURCE="$1"
VOLUME="backend_data"
IMAGE="arcadepipe-backup-tool"
DB_NAME="arcadepipe.db"

if [ ! -f "$BACKUP_SOURCE" ]; then
  echo "[restore] ERREUR : fichier introuvable : $BACKUP_SOURCE" >&2
  exit 1
fi

BACKUP_DIR="$(cd "$(dirname "$BACKUP_SOURCE")" && pwd)"
BACKUP_BASENAME="$(basename "$BACKUP_SOURCE")"

# 1/5 — Valider le backup AVANT de toucher au service : s'il est corrompu, on
# s'arrête ici. Montage sans ":ro" (sqlite3 échoue sinon, voir backup-arcadepipe-db.sh).
echo "[restore] 1/5 — Vérification d'intégrité du backup candidat..."
INTEGRITY="$(docker run --rm -v "${BACKUP_DIR}:/backup" "$IMAGE" \
  sqlite3 "/backup/${BACKUP_BASENAME}" "PRAGMA integrity_check;")"
if [ "$INTEGRITY" != "ok" ]; then
  echo "[restore] ERREUR : le backup candidat ne passe pas integrity_check : $INTEGRITY" >&2
  exit 1
fi
echo "[restore] OK : backup valide."

# 2/5 — Arrêter le backend avant d'écrire dans le volume (le site reste en
# ligne, seules les routes /api/* échouent pendant la restauration).
echo "[restore] 2/5 — Arrêt du conteneur backend..."
(cd ~/arcadepipe && docker compose stop backend)

# 3/5 — Purger les -wal/-shm de l'ANCIENNE base avant la copie. Piège classique
# en mode WAL : sinon SQLite rejouerait le journal de l'ancienne base sur la
# nouvelle (corruption silencieuse). Le fichier de ".backup" est autonome ;
# SQLite recrée un -wal propre au premier accès.
echo "[restore] 3/5 — Nettoyage des fichiers -wal/-shm de l'ancienne base..."
docker run --rm -v "${VOLUME}:/data" "$IMAGE" \
  sh -c "rm -f /data/${DB_NAME}-wal /data/${DB_NAME}-shm"

# 4/5 — Copier le backup dans le volume. `chown 1000:1000` : le conteneur jetable
# est root, mais le backend tourne en "appuser" (uid 1000) ; sans chown la base
# serait en lecture seule pour lui ("attempt to write a readonly database").
echo "[restore] 4/5 — Copie du backup dans le volume..."
docker run --rm -v "${BACKUP_DIR}:/backup:ro" -v "${VOLUME}:/data" "$IMAGE" \
  sh -c "cp /backup/${BACKUP_BASENAME} /data/${DB_NAME} && chown 1000:1000 /data/${DB_NAME}"

# 5/5 — Redémarrer le backend et vérifier que l'API répond.
echo "[restore] 5/5 — Redémarrage du backend..."
(cd ~/arcadepipe && docker compose start backend)

# Sondage plutôt qu'un sleep fixe : le temps de démarrage varie (3 s s'est révélé
# trop court une fois sur deux).
for i in $(seq 1 10); do
  if docker exec arcadepipe-backend-1 python3 -c \
      "import urllib.request as u; u.urlopen('http://localhost:8000/api/health', timeout=2)" 2>/dev/null; then
    echo "[restore] OK — backend relancé et /api/health répond."
    break
  fi
  if [ "$i" = "10" ]; then
    echo "[restore] ATTENTION : /api/health ne répond toujours pas après 10s — vérifier 'docker logs arcadepipe-backend-1'." >&2
    exit 1
  fi
  sleep 1
done

echo "[restore] Terminé $(date -Iseconds)"
