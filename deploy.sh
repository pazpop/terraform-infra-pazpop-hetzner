#!/usr/bin/env bash
# Déploie une stack Docker Compose (traefik, portal, arcadepipe ou gramps) sur le VPS :
# transfert, pull, démarrage, vérification — regroupés pour n'en oublier aucun en
# plein incident.
#
# Usage : ./deploy.sh <traefik|portal|arcadepipe|gramps> [--dry-run]
set -euo pipefail

USAGE="Usage: ./deploy.sh <traefik|portal|arcadepipe|gramps> [--dry-run]"
DRY_RUN=false
STACK=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    traefik|portal|arcadepipe|gramps) STACK="$arg" ;;
    *)
      echo "Argument inconnu : '$arg'" >&2
      echo "$USAGE" >&2
      exit 1
      ;;
  esac
done
if [ -z "$STACK" ]; then
  echo "$USAGE" >&2
  exit 1
fi

SSH_KEY="$HOME/.ssh/arcadepipe_vps"
SSH_USER="deploy"
SSH_PORT="2222"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/terraform"
DOCKER_DIR="$SCRIPT_DIR/docker"
TAR_PATH="/tmp/${STACK}-deploy.tar.gz"

# Exécute la commande, ou l'affiche seulement en --dry-run.
run() {
  if $DRY_RUN; then
    printf '[dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

# Lance une commande sur le VPS.
remote() {
  ssh -n -p "$SSH_PORT" -i "$SSH_KEY" "$SSH_USER@$HOST" "$1"
}

# gramps : .env (domaine, exposition) et config.cfg (secrets) sont gitignorés et
# voyagent dans l'archive. Absent, config.cfg serait créé par Docker comme un
# DOSSIER sur le VPS, et le conteneur refuserait de démarrer.
if [ "$STACK" = "gramps" ]; then
  for f in .env config.cfg; do
    if [ ! -f "$DOCKER_DIR/gramps/$f" ]; then
      echo "docker/gramps/$f manquant : cp docker/gramps/$f.example docker/gramps/$f (voir docker/gramps/README.md)" >&2
      exit 1
    fi
  done
  # tr -d '\r' : un .env enregistré sous Windows finit ses lignes par un retour chariot.
  GRAMPS_DOMAIN="$(sed -n 's/^GRAMPS_DOMAIN=//p' "$DOCKER_DIR/gramps/.env" | tail -n 1 | tr -d '\r')"
  GRAMPS_EXPOSE="$(sed -n 's/^GRAMPS_EXPOSE=//p' "$DOCKER_DIR/gramps/.env" | tail -n 1 | tr -d '\r')"
fi

HOST="$(cd "$TERRAFORM_DIR" && tofu output -raw server_ip)"

echo "== Déploiement de '$STACK' sur $HOST $($DRY_RUN && echo '(dry-run — rien ne sera modifié)') =="

# traefik-public est partagé par toutes les stacks (external: true) : créé ici, sans
# erreur s'il existe déjà.
run remote "docker network create traefik-public 2>/dev/null || true"

# L'archive locale est supprimée à la sortie, même si le transfert échoue : celle
# de gramps contient ses secrets.
trap 'rm -f "$TAR_PATH"' EXIT
run tar -czf "$TAR_PATH" -C "$DOCKER_DIR" "$STACK"
run scp -P "$SSH_PORT" -i "$SSH_KEY" "$TAR_PATH" "$SSH_USER@$HOST:~/${STACK}.tar.gz"
# En deux temps. D'abord l'archive est extraite par-dessus le dossier en place
# et les images sont téléchargées (sans ce pull, une image tirée d'un registre
# resterait celle déjà présente sur le VPS, même périmée). Si le registre ne
# répond pas, le script s'arrête ici : les conteneurs en marche ne sont pas touchés.
run remote "tar xzf ~/${STACK}.tar.gz && cd ~/$STACK && docker compose pull"
# Ensuite seulement, le dossier est vidé et extrait de nouveau : un fichier
# supprimé du dépôt ne reste pas sur le VPS (Traefik chargerait encore un ancien
# dynamic/*.yml). Rien n'y est à garder : les données sont dans des volumes
# Docker, et les fichiers non versionnés de gramps voyagent dans l'archive.
# $STACK vaut forcément l'un des quatre noms acceptés plus haut.
run remote "rm -rf ~/$STACK && tar xzf ~/${STACK}.tar.gz && rm ~/${STACK}.tar.gz"

# --force-recreate : sans lui, un conteneur dont seul un fichier monté a changé
# (traefik.yml, config.cfg) n'est pas recréé et garde l'ancienne configuration.
# --remove-orphans : un service retiré du compose est arrêté.
# --wait : attend que les conteneurs soient démarrés et, s'ils ont un contrôle de
# santé, « healthy » ; échoue sinon. Un conteneur sans contrôle de santé (ceux de
# gramps) passe dès qu'il a démarré, même s'il s'arrête aussitôt après : pour
# eux, c'est la vérification de l'adresse, plus bas, qui fait foi.
READY=true
run remote "cd ~/$STACK && docker compose up -d --build --force-recreate --remove-orphans --wait --wait-timeout 60" || READY=false

# Sans -a : ne supprime que les images que plus rien ne nomme.
run remote "docker image prune -f"

if $DRY_RUN; then
  echo
  echo "== Dry-run terminé : rien n'a été transféré, construit ou démarré =="
  exit 0
fi

FAILED=false

# Vérifie qu'une adresse répond 200. Cinq essais : juste après son démarrage, un
# service met quelques secondes à répondre derrière Traefik.
check_url() {
  local code="???"
  for _ in 1 2 3 4 5; do
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$1" || true)"
    [ "$code" = "200" ] && break
    sleep 3
  done
  if [ "$code" = "200" ]; then
    echo "$1 : ✅"
  else
    echo "$1 : ❌ $code"
    FAILED=true
  fi
}

echo
echo "===================== Résumé ====================="
remote "cd ~/$STACK && docker compose ps --format 'table {{.Name}}\t{{.Status}}'"
echo "----------------------------------------------------"
if $READY; then
  echo "Conteneurs : ✅ démarrés (et sains, pour ceux qui ont un contrôle de santé)"
else
  echo "Conteneurs : ❌ pas prêts (sur le VPS : cd ~/$STACK && docker compose logs)"
  FAILED=true
fi

case "$STACK" in
  traefik)
    # Informatif : une course de démarrage bénigne (docker-socket-proxy pas encore
    # prêt) laisse toujours une ligne d'erreur dans ces logs.
    echo "Derniers logs Traefik (ne déterminent pas le succès) :"
    remote "docker logs traefik-traefik-1 --tail 10 2>&1"
    ;;
  portal)
    check_url "https://game.pazpop.net/"
    ;;
  gramps)
    # Non exposé (premier démarrage) : Traefik ne route rien, seul l'état des conteneurs compte.
    if [ "$GRAMPS_EXPOSE" = "true" ]; then
      check_url "https://$GRAMPS_DOMAIN/"
    else
      echo "$GRAMPS_DOMAIN : non exposé (GRAMPS_EXPOSE=false) — créer le compte propriétaire, voir docker/gramps/README.md"
    fi
    ;;
  arcadepipe)
    check_url "https://arcadepipe.pazpop.net/"
    check_url "https://arcadepipe.pazpop.net/api/health"
    ;;
esac
echo "===================================================="

if $FAILED; then
  exit 1
fi
