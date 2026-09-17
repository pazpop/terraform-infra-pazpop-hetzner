#!/usr/bin/env bash
# Restaure la DB arcadepipe depuis un fichier de backup produit par
# backup-arcadepipe-db.sh. Usage : ./restore-arcadepipe-db.sh <chemin-du-backup>
#
# Procédure volontairement scriptée plutôt que documentée en texte seul :
# un incident réel n'est pas le moment idéal pour taper des commandes à la
# main sans se tromper. Voir backup/README.md pour le déroulé humain
# équivalent et les explications de chaque étape.
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

# Étape 1/5 — Valider le backup AVANT de toucher à quoi que ce soit de
# vivant. Si le fichier choisi est lui-même corrompu (improbable si
# backup-arcadepipe-db.sh a fait son travail, mais un fichier copié à la
# main depuis ailleurs n'a pas cette garantie), on s'arrête ici, le service
# actuel n'a pas encore été touché.
# Montage PAS en lecture seule : testé en réel côté backup-arcadepipe-db.sh,
# sqlite3 échoue systématiquement avec ":ro" même pour une simple lecture —
# il a besoin de pouvoir créer des fichiers de verrouillage dans le
# répertoire, quelle que soit l'opération demandée.
echo "[restore] 1/5 — Vérification d'intégrité du backup candidat..."
INTEGRITY="$(docker run --rm -v "${BACKUP_DIR}:/backup" "$IMAGE" \
  sqlite3 "/backup/${BACKUP_BASENAME}" "PRAGMA integrity_check;")"
if [ "$INTEGRITY" != "ok" ]; then
  echo "[restore] ERREUR : le backup candidat ne passe pas integrity_check : $INTEGRITY" >&2
  exit 1
fi
echo "[restore] OK : backup valide."

# Étape 2/5 — Arrêter le backend AVANT d'écrire dans le volume. Le
# frontend/Traefik peuvent rester en marche (le site répond, seules les
# routes /api/* échoueront pendant la restauration) — pas besoin d'une
# coupure totale pour restaurer uniquement la DB.
echo "[restore] 2/5 — Arrêt du conteneur backend..."
(cd ~/arcadepipe && docker compose stop backend)

# Étape 3/5 — Purger les fichiers -wal/-shm de l'ANCIENNE base AVANT de
# copier la nouvelle. C'est LE piège classique d'une restauration SQLite en
# mode WAL : si on copie juste le nouveau .db par-dessus l'ancien sans
# supprimer son -wal/-shm, SQLite tentera de rejouer au prochain démarrage
# un journal WAL qui appartient à l'ANCIENNE base sur la NOUVELLE — corruption
# silencieuse quasi garantie, découverte bien plus tard. Le fichier produit
# par ".backup" (voir backup-arcadepipe-db.sh) est un fichier autonome sans
# WAL actif ; SQLite recréera un -wal propre tout seul au premier accès.
echo "[restore] 3/5 — Nettoyage des fichiers -wal/-shm de l'ancienne base..."
docker run --rm -v "${VOLUME}:/data" "$IMAGE" \
  sh -c "rm -f /data/${DB_NAME}-wal /data/${DB_NAME}-shm"

# Étape 4/5 — Copier le backup validé dans le volume, à la place de
# l'ancienne base. `chown 1000:1000` après la copie : le conteneur jetable
# tourne en root, donc le fichier copié appartient à root — mais le backend
# tourne en "appuser" (uid 1000, voir backend/Dockerfile) sur un système de
# fichiers non-root. Sans ce chown, le fichier reste lisible mais jamais
# inscriptible par le backend une fois relancé ("attempt to write a
# readonly database") — trouvé lors du premier test réel de ce script.
echo "[restore] 4/5 — Copie du backup dans le volume..."
docker run --rm -v "${BACKUP_DIR}:/backup:ro" -v "${VOLUME}:/data" "$IMAGE" \
  sh -c "cp /backup/${BACKUP_BASENAME} /data/${DB_NAME} && chown 1000:1000 /data/${DB_NAME}"

# Étape 5/5 — Redémarrer le backend, vérifier que l'API répond.
echo "[restore] 5/5 — Redémarrage du backend..."
(cd ~/arcadepipe && docker compose start backend)

# Sondage plutôt qu'un sleep fixe : le temps de démarrage réel varie (testé
# en conditions réelles : 3s pile s'est révélé trop court une fois sur deux),
# un délai fixe est soit trop court (faux négatif) soit du temps perdu à
# chaque restauration si on le mettait trop long "pour être sûr".
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
