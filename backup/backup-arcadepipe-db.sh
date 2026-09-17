#!/usr/bin/env bash
# Backup quotidien de la DB SQLite d'arcadepipe (volume Docker "backend_data",
# voir docker/arcadepipe/docker-compose.yml). Lancé par arcadepipe-backup.timer.
#
# set -euo pipefail : un timer systemd qui échoue est invisible par défaut —
# rien ne le signale tant que personne ne va lire `systemctl status` de son
# propre chef. Sans ces trois options, un échec au milieu du script (ex: le
# conteneur jetable ne démarre pas) continuerait sur les lignes suivantes et
# pourrait laisser croire qu'un backup a été pris alors que non. Avec, le
# service systemd passe en "failed" et journalctl garde la trace de l'erreur
# exacte — visible par n'importe quel outil de supervision branché dessus
# plus tard (voir Roadmap : alertes webhook).
set -euo pipefail

# Unique variable qui isole la DESTINATION du reste du script — le jour où
# un stockage distant remplace/complète le disque local (rclone, etc.), ça
# s'ajoute EN PLUS de la logique ci-dessous (une étape `rclone sync
# "$BACKUP_DEST" remote:bucket` après la rétention), ça ne la remplace pas :
# le disque local reste un tampon même avec un remote branché. Voir
# backup/README.md pour le détail de ce chemin d'évolution, non implémenté
# ici (pas de remote pour l'instant, YAGNI).
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

# ".backup" (pas "VACUUM INTO") : c'est l'API de backup officielle de SQLite
# (Online Backup API), conçue précisément pour copier une base VIVANTE de
# façon cohérente, y compris en mode WAL — contrairement à un simple `cp` du
# fichier .db qui risquerait de capturer un état à cheval entre le fichier
# principal et le -wal, donc potentiellement corrompu. VACUUM INTO fait aussi
# le travail mais son objectif premier est la compaction, pas le backup.
#
# Aucun montage sqlite3 n'est en lecture seule (:ro) dans ce script, contrai-
# rement à l'intention de départ — testé en réel, ":ro" fait systématiquement
# échouer sqlite3 avec "unable to open database file", MÊME pour une simple
# lecture et MÊME sur un fichier déjà autonome (pas en mode WAL) : SQLite a
# besoin de pouvoir créer des fichiers de verrouillage/journal dans le même
# répertoire que la base, quelle que soit l'opération demandée. Le conteneur
# n'écrit jamais VOLONTAIREMENT dans les volumes montés ici, mais SQLite
# lui-même l'exige pour fonctionner, y compris en lecture seule côté SQL.
docker run --rm \
  -v "${VOLUME}:/source" \
  -v "${DAILY_DIR}:/backup" \
  "$IMAGE" \
  sqlite3 "/source/${DB_NAME}" ".backup '/backup/${BACKUP_FILE}'"

BACKUP_PATH="${DAILY_DIR}/${BACKUP_FILE}"

# Vérification IMMÉDIATE (pas seulement au moment d'une restauration) : un
# `.backup` sur une base déjà corrompue en source produit un fichier de
# sortie tout aussi corrompu, sans qu'aucune erreur ne remonte. Sans ce
# contrôle, on découvrirait le problème seulement le jour où on a
# effectivement besoin de restaurer — c'est-à-dire le pire moment possible.
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

# Promotion hebdomadaire : le dimanche (date +%u == 7), le backup du jour est
# AUSSI copié dans weekly/ — une seule prise de backup par run, pas une
# deuxième invocation de sqlite3 (le fichier daily/ déjà validé ci-dessus
# suffit, pas besoin de repasser par le conteneur jetable).
if [ "$(date +%u)" = "7" ]; then
  cp "$BACKUP_PATH" "${WEEKLY_DIR}/${BACKUP_FILE}"
  echo "[backup] Copié aussi dans weekly/ (dimanche)"
fi

# Rétention : garder les N plus récents par dossier, supprimer le reste.
# `xargs -r` (pas `xargs` seul) : sans le -r, un dossier avec 7 fichiers ou
# moins (donc rien à supprimer, `tail` ne produit aucune ligne) ferait quand
# même tourner `rm` sans argument -> `rm` sans fichier renvoie une erreur et
# ferait échouer le script pour de mauvaises raisons, précisément le genre
# de script qui tourne des mois à 3h du matin sans être relu.
purge_old() {
  local dir="$1"
  local keep="$2"
  ls -t "$dir" | tail -n "+$((keep + 1))" | xargs -r -I{} rm -- "$dir/{}"
}
purge_old "$DAILY_DIR" 7
purge_old "$WEEKLY_DIR" 4

echo "[backup] Terminé $(date -Iseconds) — $(ls "$DAILY_DIR" | wc -l) daily, $(ls "$WEEKLY_DIR" | wc -l) weekly"
