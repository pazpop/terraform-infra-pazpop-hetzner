#!/usr/bin/env bash
# Test de bout en bout du backup/restauration contre la VRAIE API en prod :
# insère un score de test, backup, suppression, restauration, vérifie le retour,
# nettoie (voir backup/README.md, « Test réel exécuté »).
#
# Usage : ./test-backup-restore.sh
set -euo pipefail

API_BASE="https://arcadepipe.pazpop.net"
SSH_HOST="arcadepipe-vps"   # alias défini dans ~/.ssh/config
REMOTE_BACKUP_SCRIPT="~/backup/backup-arcadepipe-db.sh"
REMOTE_RESTORE_SCRIPT="~/backup/restore-arcadepipe-db.sh"

# Nom unique par run : le nettoyage ne supprime que ce nom précis.
TEST_PLAYER="E2ETEST_$(date +%s)"

# Supprime le score de test sur la VRAIE base (étape 3 et nettoyage). Via Python :
# l'image du backend n'a pas le binaire sqlite3.
delete_test_score() {
  ssh "$SSH_HOST" "docker exec arcadepipe-backend-1 python3 -c \"
import sqlite3
conn = sqlite3.connect('/data/arcadepipe.db')
conn.execute(\\\"DELETE FROM scores WHERE player_name = '${TEST_PLAYER}'\\\")
conn.commit()
conn.close()
\"" >/dev/null
}

# Nettoyage garanti même en cas d'échec (trap sur EXIT) : pas de faux scores dans le vrai classement.
cleanup() {
  echo "[test] Nettoyage : suppression de ${TEST_PLAYER}..."
  delete_test_score || true
}
trap cleanup EXIT

echo "[test] Joueur de test : ${TEST_PLAYER}"

echo "[test] 1/6 — Insertion du score de test..."
curl -sS -f -X POST "${API_BASE}/api/scores" \
  -H "Content-Type: application/json" \
  -d "{\"player_name\":\"${TEST_PLAYER}\",\"score\":42,\"wave\":1,\"kills\":1}" >/dev/null

echo "[test] 2/6 — Backup (doit capturer ${TEST_PLAYER})..."
BACKUP_OUTPUT="$(ssh "$SSH_HOST" "$REMOTE_BACKUP_SCRIPT")"
echo "$BACKUP_OUTPUT"
# Extrait le chemin de la ligne "[backup] OK : /chemin/fichier.db (20K, ...)".
BACKUP_PATH="$(echo "$BACKUP_OUTPUT" | awk -F'OK : ' '/OK :/{split($2,a," "); print a[1]}')"
if [ -z "$BACKUP_PATH" ]; then
  echo "[test] ERREUR : impossible de déterminer le fichier de backup produit." >&2
  exit 1
fi
echo "[test] Fichier de backup : $BACKUP_PATH"

echo "[test] 3/6 — Suppression du score en direct (simule une perte de données)..."
delete_test_score
if curl -sS "${API_BASE}/api/scores?limit=100" | grep -q "$TEST_PLAYER"; then
  echo "[test] ERREUR : le score de test est toujours présent après suppression." >&2
  exit 1
fi
echo "[test] Confirmé absent en direct."

echo "[test] 4/6 — Restauration depuis le backup..."
ssh "$SSH_HOST" "$REMOTE_RESTORE_SCRIPT '$BACKUP_PATH'"

echo "[test] 5/6 — Vérification que le score est revenu..."
if curl -sS "${API_BASE}/api/scores?limit=100" | grep -q "$TEST_PLAYER"; then
  echo "[test] ✅ SUCCÈS — ${TEST_PLAYER} a bien été restauré."
else
  echo "[test] ❌ ÉCHEC — ${TEST_PLAYER} absent après restauration." >&2
  exit 1
fi

echo "[test] 6/6 — Nettoyage (voir aussi le trap EXIT, filet de sécurité en cas d'échec plus haut)."
# La suppression est faite par cleanup() (trap EXIT ci-dessus).
