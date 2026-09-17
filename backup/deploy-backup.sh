#!/usr/bin/env bash
# Déploie le mécanisme de backup (script, image jetable, unités systemd) sur
# la VPS. Séparé de deploy.sh à la racine : ce dernier est conçu pour une
# forme précise (stack docker-compose : tar/scp/ssh puis `docker compose
# pull && up`), qui ne correspond à rien ici — pas de docker-compose.yml, pas
# d'URL à vérifier en healthcheck. Un backup est un artefact host-level
# (script + unités systemd), même nature que terraform/cloud-init.yaml mais
# appliqué après coup plutôt qu'au provisioning initial du VPS.
#
# Idempotent : relançable sans risque, ne duplique rien (systemctl enable
# sur un timer déjà activé ne fait rien, `docker build` réutilise le cache).
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

# Pas de "-n" ici (contrairement à deploy.sh) : "-n" redirige stdin depuis
# /dev/null, ce qui viderait ce heredoc avant qu'il n'atteigne "bash -s" côté
# distant — le script s'exécuterait sur une entrée vide, sans rien faire, et
# sans la moindre erreur visible (trouvé exactement comme ça au premier test
# réel de ce script : "déploiement terminé" affiché alors que rien n'avait
# tourné côté VPS).
ssh -p "$SSH_PORT" -i "$SSH_KEY" "$SSH_USER@$HOST" bash -s <<'REMOTE_SCRIPT'
set -euo pipefail

mkdir -p ~/backup
tar xzf ~/backup.tar.gz -C ~/backup
rm ~/backup.tar.gz
chmod +x ~/backup/backup-arcadepipe-db.sh ~/backup/restore-arcadepipe-db.sh

echo "-- Build de l'image jetable --"
docker build -t arcadepipe-backup-tool ~/backup

# Créé une seule fois avec sudo (deploy est NOPASSWD:ALL, voir cloud-init.yaml)
# puis chown vers deploy : /var/backups appartient à root par défaut sur
# Ubuntu, un utilisateur standard ne peut pas y créer de sous-dossier tout
# seul. Après ce chown, le timer (qui tourne en tant que "deploy", jamais en
# root, voir arcadepipe-backup.service) n'a plus besoin d'aucun privilège
# élevé pour écrire ses backups au quotidien.
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
