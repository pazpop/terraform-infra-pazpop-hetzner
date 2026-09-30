#!/usr/bin/env bash
# Déploie le backup de Gramps Web (script, image jetable, unités systemd) sur la VPS.
# Pendant de deploy-backup.sh (arcadepipe), laissé intact : les deux backups sont
# indépendants et se déploient séparément.
# Idempotent : relançable sans risque.
#
# Usage : ./deploy-backup-gramps.sh
set -euo pipefail

SSH_KEY="$HOME/.ssh/arcadepipe_vps"
SSH_USER="deploy"
SSH_PORT="2222"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/../terraform"
TAR_PATH="/tmp/gramps-backup-deploy.tar.gz"

HOST="$(cd "$TERRAFORM_DIR" && tofu output -raw server_ip)"

echo "== Déploiement du backup Gramps Web sur $HOST =="

# Même Dockerfile (alpine + sqlite3, épinglé par digest) que le backup arcadepipe.
tar -czf "$TAR_PATH" -C "$SCRIPT_DIR" \
  Dockerfile backup-gramps.sh gramps-backup.service gramps-backup.timer
scp -P "$SSH_PORT" -i "$SSH_KEY" "$TAR_PATH" "$SSH_USER@$HOST:~/backup-gramps.tar.gz"
rm -f "$TAR_PATH"

# Pas de "-n" ici : il viderait le heredoc avant "bash -s" (bug déjà rencontré, voir README).
ssh -p "$SSH_PORT" -i "$SSH_KEY" "$SSH_USER@$HOST" bash -s <<'REMOTE_SCRIPT'
set -euo pipefail

mkdir -p ~/backup-gramps
tar xzf ~/backup-gramps.tar.gz -C ~/backup-gramps
rm ~/backup-gramps.tar.gz
chmod +x ~/backup-gramps/backup-gramps.sh

echo "-- Build de l'image jetable --"
docker build -t gramps-backup-tool ~/backup-gramps

echo "-- Préparation de /var/backups/gramps --"
sudo mkdir -p /var/backups/gramps/daily /var/backups/gramps/weekly
sudo chown -R deploy:deploy /var/backups/gramps
sudo chmod 700 /var/backups/gramps

echo "-- Installation des unités systemd --"
sudo cp ~/backup-gramps/gramps-backup.service ~/backup-gramps/gramps-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now gramps-backup.timer

echo "-- Statut --"
systemctl list-timers gramps-backup.timer --no-pager
REMOTE_SCRIPT

echo
echo "== Déploiement terminé =="
echo "Test immédiat : ssh ... 'sudo systemctl start gramps-backup.service && journalctl -u gramps-backup.service -n 30 --no-pager'"
