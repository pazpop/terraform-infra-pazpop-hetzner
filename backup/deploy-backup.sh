#!/usr/bin/env bash
# Déploie le mécanisme de backup (script, image jetable, unités systemd) sur la VPS.
# Séparé de deploy.sh, conçu pour des stacks docker-compose : un backup est un
# artefact de l'hôte, sans docker-compose.yml ni URL à vérifier.
# Idempotent : relançable sans risque.
#
# Usage : ./deploy-backup.sh
set -euo pipefail

SSH_KEY="$HOME/.ssh/arcadepipe_vps"
SSH_USER="deploy"
SSH_PORT="2222"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/../terraform"
TAR_PATH="/tmp/arcadepipe-backup-deploy.tar.gz"

HOST="$(cd "$TERRAFORM_DIR" && tofu output -raw server_ip)"

echo "== Déploiement du backup arcadepipe sur $HOST =="

tar -czf "$TAR_PATH" -C "$SCRIPT_DIR" \
  Dockerfile backup-arcadepipe-db.sh restore-arcadepipe-db.sh \
  arcadepipe-backup.service arcadepipe-backup.timer
scp -P "$SSH_PORT" -i "$SSH_KEY" "$TAR_PATH" "$SSH_USER@$HOST:~/backup.tar.gz"
rm -f "$TAR_PATH"

# Pas de "-n" ici : il viderait le heredoc avant "bash -s", et le script distant
# s'exécuterait à vide sans erreur visible.
ssh -p "$SSH_PORT" -i "$SSH_KEY" "$SSH_USER@$HOST" bash -s <<'REMOTE_SCRIPT'
set -euo pipefail

mkdir -p ~/backup
tar xzf ~/backup.tar.gz -C ~/backup
rm ~/backup.tar.gz
chmod +x ~/backup/backup-arcadepipe-db.sh ~/backup/restore-arcadepipe-db.sh

echo "-- Build de l'image jetable --"
docker build -t arcadepipe-backup-tool ~/backup

# /var/backups appartient à root : créé une fois avec sudo puis chown vers deploy,
# pour que le timer (qui tourne en "deploy", jamais en root) n'ait besoin d'aucun
# privilège élevé.
echo "-- Préparation de /var/backups/arcadepipe --"
sudo mkdir -p /var/backups/arcadepipe/daily /var/backups/arcadepipe/weekly
sudo chown -R deploy:deploy /var/backups/arcadepipe

echo "-- Installation des unités systemd --"
sudo cp ~/backup/arcadepipe-backup.service ~/backup/arcadepipe-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now arcadepipe-backup.timer

echo "-- Statut --"
systemctl status arcadepipe-backup.timer --no-pager -l | head -8
systemctl list-timers arcadepipe-backup.timer --no-pager
REMOTE_SCRIPT

echo
echo "== Déploiement terminé =="
echo "Test immédiat possible : ssh arcadepipe-vps 'sudo systemctl start arcadepipe-backup.service && journalctl -u arcadepipe-backup.service -n 20 --no-pager'"
