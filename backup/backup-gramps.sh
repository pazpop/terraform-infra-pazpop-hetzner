#!/usr/bin/env bash
# Backup quotidien de Gramps Web (stack docker/gramps), lancé par gramps-backup.timer.
#
# Contenu de chaque archive gramps_YYYY-MM-DD_HHMM.tar.gz :
#   db/<id-arbre>/...   l'arbre (base SQLite copiée par l'API .backup, jamais par cp)
#   users/users.sqlite  les comptes Gramps Web (même méthode)
#   secret/             la clé Flask (sans elle, toutes les sessions sont invalidées)
#   media.tar           photos et scans d'actes
#
# Complément, pas remplacement : l'export Gramps XML (.gramps) fait depuis l'interface
# ou par le script du repo gramps-web reste le format portable, versionné dans
# arbre-genealogique. Cette archive-ci sert à remettre le service en l'état.
#
# set -euo pipefail : un échec fait passer le service systemd en "failed" (trace
# dans journalctl) au lieu de laisser croire qu'un backup a été pris.
set -euo pipefail
source "$(dirname "$0")/common.sh"

# Destination locale ; un stockage distant s'ajoutera en plus (prioritaire ici : l'arbre
# ne se reconstruit pas).
BACKUP_DEST="/var/backups/gramps"
ARCHIVE="gramps_$(date +%Y-%m-%d_%H%M).tar.gz"

DAILY_DIR="$BACKUP_DEST/daily"
WEEKLY_DIR="$BACKUP_DEST/weekly"
mkdir -p "$DAILY_DIR" "$WEEKLY_DIR"
# Données personnelles (personnes vivantes) : illisibles pour les autres comptes.
chmod 700 "$BACKUP_DEST"

WORK="$(mktemp -d "$BACKUP_DEST/.work.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

echo "[backup-gramps] Démarrage $(date -Iseconds)"

# Pas de montage ":ro" sur les volumes SQLite : sqlite3 doit pouvoir créer ses fichiers
# de verrou même pour lire. -readonly : une base absente fait échouer la copie au
# lieu d'être créée vide.
# `.backup` copie une base vivante de façon cohérente ; chaque copie est vérifiée tout
# de suite par integrity_check (une source corrompue donnerait une copie corrompue).
docker run --rm \
  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  -v gramps_db:/src/db \
  -v gramps_users:/src/users \
  -v gramps_secret:/src/secret:ro \
  -v gramps_media:/src/media:ro \
  -v "$WORK:/out" \
  "$IMAGE" sh -euc '
    # Le conteneur écrit en root : la copie est rendue à "deploy" à la sortie,
    # même après un échec. Sinon le nettoyage (trap rm -rf, plus haut) échoue
    # et une copie en clair reste sur le disque.
    trap "chown -R $HOST_UID:$HOST_GID /out" EXIT
    mkdir -p /out/db /out/users
    cd /src/db
    for tree in */; do
      tree="${tree%/}"
      mkdir -p "/out/db/$tree"
      for f in "$tree"/*; do
        [ -e "$f" ] || continue
        case "$f" in
          *.db)
            sqlite3 -readonly "$f" ".backup \"/out/db/$f\""
            res="$(sqlite3 "/out/db/$f" "PRAGMA integrity_check;")"
            [ "$res" = "ok" ] || { echo "integrity_check KO sur $f : $res" >&2; exit 1; }
            ;;
          *-wal|*-shm|*-journal|*.lock|*/lock) ;;  # état transitoire de la base vivante : jamais copié
          *) cp -a "$f" "/out/db/$tree/" ;;
        esac
      done
    done
    sqlite3 -readonly /src/users/users.sqlite ".backup /out/users/users.sqlite"
    res="$(sqlite3 /out/users/users.sqlite "PRAGMA integrity_check;")"
    [ "$res" = "ok" ] || { echo "integrity_check KO sur users.sqlite : $res" >&2; exit 1; }
    cp -a /src/secret /out/secret
    tar -C /src -cf /out/media.tar media
  '

# Au moins un arbre copié : un volume gramps_db vide (stack jamais initialisée, ou nom de
# volume changé) donnerait sinon une archive « réussie » qui ne contient rien.
if ! find "$WORK/db" -name '*.db' -type f | grep -q .; then
  echo "[backup-gramps] ERREUR : aucune base d'arbre trouvée dans le volume gramps_db" >&2
  exit 1
fi

tar -C "$WORK" -czf "$DAILY_DIR/$ARCHIVE" .
chmod 600 "$DAILY_DIR/$ARCHIVE"
echo "[backup-gramps] OK : $DAILY_DIR/$ARCHIVE ($(du -h "$DAILY_DIR/$ARCHIVE" | cut -f1))"

rotation "$DAILY_DIR/$ARCHIVE" "[backup-gramps]"
