#!/usr/bin/env bash
# Restaure la DB arcadepipe depuis un backup de backup-arcadepipe-db.sh.
# Usage : ./restore-arcadepipe-db.sh <chemin-du-backup>
# Scripté plutôt que documenté : un incident n'est pas le moment de taper à la
# main. Déroulé humain équivalent : backup/README.md.
set -euo pipefail
source "$(dirname "$0")/common.sh"

if [ $# -ne 1 ]; then
  echo "Usage: $0 <chemin-du-fichier-de-backup.db>" >&2
  exit 1
fi

BACKUP_SOURCE="$1"
VOLUME="backend_data"
DB_NAME="arcadepipe.db"
# Copie de la base en place, prise juste avant de l'écraser (une seule, remplacée à chaque restauration).
SAFETY_DIR="/var/backups/arcadepipe/avant-restauration"

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
# ligne, seules les routes /api/* échouent pendant la restauration). Il est
# relancé à la sortie du script, même si une étape échoue.
echo "[restore] 2/5 — Arrêt du conteneur backend..."
(cd ~/arcadepipe && docker compose stop backend)
trap '(cd ~/arcadepipe && docker compose start backend)' EXIT

# Copie de la base en place avant de l'écraser : une erreur de fichier se
# rattrape en restaurant cette copie. Pas quand c'est cette copie qu'on
# restaure : elle serait écrasée avant d'avoir servi. Une base en place
# illisible n'empêche pas la restauration (c'est peut-être la raison de la
# restaurer). -readonly : sqlite3 ne crée pas une base vide si le fichier manque.
mkdir -p "$SAFETY_DIR"
if [ "$BACKUP_DIR" = "$SAFETY_DIR" ]; then
  echo "[restore] Restauration de la copie de sécurité : elle est laissée telle quelle."
elif docker run --rm -v "${VOLUME}:/data" -v "${SAFETY_DIR}:/safety" "$IMAGE" \
    sqlite3 -readonly "/data/${DB_NAME}" ".backup '/safety/${DB_NAME}'"; then
  echo "[restore] Base en place copiée dans ${SAFETY_DIR}/${DB_NAME}"
else
  echo "[restore] ATTENTION : base en place illisible, aucune copie avant restauration." >&2
fi

# 3/5 — Purger les -wal/-shm de l'ANCIENNE base avant la copie. Piège classique
# en mode WAL : sinon SQLite rejouerait le journal de l'ancienne base sur la
# nouvelle (corruption silencieuse). Le fichier de ".backup" est autonome ;
# SQLite recrée un -wal propre au premier accès.
echo "[restore] 3/5 — Nettoyage des fichiers -wal/-shm de l'ancienne base..."
docker run --rm -v "${VOLUME}:/data" "$IMAGE" \
  rm -f "/data/${DB_NAME}-wal" "/data/${DB_NAME}-shm"

# 4/5 — Copier le backup dans le volume. `chown 1000:1000` : le conteneur jetable
# est root, mais le backend tourne en "appuser" (uid 1000) ; sans chown la base
# serait en lecture seule pour lui ("attempt to write a readonly database").
# Les chemins sont passés en arguments ($1, $2), jamais collés dans la commande :
# un nom de fichier avec une espace ne la casse pas.
echo "[restore] 4/5 — Copie du backup dans le volume..."
docker run --rm -v "${BACKUP_DIR}:/backup:ro" -v "${VOLUME}:/data" "$IMAGE" \
  sh -c 'cp "$1" "$2" && chown 1000:1000 "$2"' sh "/backup/${BACKUP_BASENAME}" "/data/${DB_NAME}"

# 5/5 — Redémarrer le backend et vérifier que l'API répond.
echo "[restore] 5/5 — Redémarrage du backend..."
(cd ~/arcadepipe && docker compose start backend)

# Sondage plutôt qu'un sleep fixe : le temps de démarrage varie.
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
