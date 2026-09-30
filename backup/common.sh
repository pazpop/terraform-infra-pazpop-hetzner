# Commun aux scripts de backup (sourcé, pas exécuté).

IMAGE="backup-tool"

# Copie du dimanche dans weekly/, puis rétention : 7 quotidiens, 4 hebdomadaires.
# Usage : rotation <fichier du jour, déjà validé> ; DAILY_DIR et WEEKLY_DIR définis par l'appelant.
rotation() {
  if [ "$(date +%u)" = "7" ]; then
    cp -p "$1" "$WEEKLY_DIR/"
    echo "Copié aussi dans weekly/ (dimanche)"
  fi
  purge_old "$DAILY_DIR" 7
  purge_old "$WEEKLY_DIR" 4
  echo "Terminé $(date -Iseconds) — $(ls "$DAILY_DIR" | wc -l) daily, $(ls "$WEEKLY_DIR" | wc -l) weekly"
}

# Garde les N plus récents. `xargs -r` : rien à purger = pas d'appel à rm sans argument.
purge_old() {
  ls -t "$1" | tail -n "+$(($2 + 1))" | xargs -r -I{} rm -- "$1/{}"
}
