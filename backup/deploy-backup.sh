#!/usr/bin/env bash
# Déploie les backups (arcadepipe et Gramps Web : scripts, image jetable, unités systemd)
# sur la VPS. Séparé de deploy.sh, conçu pour des stacks docker-compose : un backup est
# un artefact de l'hôte, sans docker-compose.yml ni URL à vérifier.
# Idempotent : relançable sans risque.
#
# Usage : ./deploy-backup.sh
set -euo pipefail

SSH_KEY="$HOME/.ssh/arcadepipe_vps"
SSH_USER="deploy"
SSH_PORT="2222"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/../terraform"
TAR_PATH="/tmp/backup-deploy.tar.gz"

HOST="$(cd "$TERRAFORM_DIR" && tofu output -raw server_ip)"

echo "== Déploiement des backups sur $HOST =="

tar -czf "$TAR_PATH" -C "$SCRIPT_DIR" \
  Dockerfile common.sh \
  backup-arcadepipe-db.sh restore-arcadepipe-db.sh arcadepipe-backup.service arcadepipe-backup.timer \
  backup-gramps.sh gramps-backup.service gramps-backup.timer
scp -P "$SSH_PORT" -i "$SSH_KEY" "$TAR_PATH" "$SSH_USER@$HOST:~/backup.tar.gz"
rm -f "$TAR_PATH"

# Pas de "-n" ici : il viderait le heredoc avant "bash -s", et le script distant
# s'exécuterait à vide sans erreur visible.
ssh -p "$SSH_PORT" -i "$SSH_KEY" "$SSH_USER@$HOST" bash -s <<'REMOTE_SCRIPT'
set -euo pipefail

# Dossier vidé avant l'extraction : un script supprimé du dépôt ne reste pas
# sur le VPS. Les sauvegardes, elles, sont dans /var/backups. Une unité systemd
# retirée du dépôt reste installée : `sudo systemctl disable --now` à la main.
rm -rf ~/backup
mkdir -p ~/backup
tar xzf ~/backup.tar.gz -C ~/backup
rm ~/backup.tar.gz
chmod +x ~/backup/*.sh

echo "-- Build de l'image jetable --"
docker build -t backup-tool ~/backup

# /var/backups appartient à root : créé une fois avec sudo puis chown vers deploy,
# pour que les timers (qui tournent en "deploy", jamais en root) n'aient besoin d'aucun
# privilège élevé. Gramps : données personnelles, dossier en 700.
echo "-- Préparation de /var/backups --"
for app in arcadepipe gramps; do
  sudo mkdir -p "/var/backups/$app/daily" "/var/backups/$app/weekly"
  sudo chown -R deploy:deploy "/var/backups/$app"
done
sudo chmod 700 /var/backups/gramps

echo "-- Installation des unités systemd --"
sudo cp ~/backup/*.service ~/backup/*.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now arcadepipe-backup.timer gramps-backup.timer

echo "-- Statut --"
systemctl list-timers arcadepipe-backup.timer gramps-backup.timer --no-pager
REMOTE_SCRIPT

echo
echo "== Déploiement terminé =="
echo "Test immédiat : ssh arcadepipe-vps 'sudo systemctl start arcadepipe-backup.service gramps-backup.service && journalctl -u arcadepipe-backup.service -u gramps-backup.service -n 30 --no-pager'"
