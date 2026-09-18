#!/usr/bin/env bash
# Déploie une stack Docker Compose (traefik, portal ou arcadepipe) sur le VPS :
# tar, scp, ssh, pull, up — regroupés pour n'en oublier aucun en plein incident.
#
# Usage : ./deploy.sh <traefik|portal|arcadepipe> [--dry-run]
set -euo pipefail

DRY_RUN=false
STACK=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    traefik|portal|arcadepipe) STACK="$arg" ;;
    *)
      echo "Argument inconnu : '$arg'" >&2
      echo "Usage: ./deploy.sh <traefik|portal|arcadepipe> [--dry-run]" >&2
      exit 1
      ;;
  esac
done
if [ -z "$STACK" ]; then
  echo "Usage: ./deploy.sh <traefik|portal|arcadepipe> [--dry-run]" >&2
  exit 1
fi

SSH_KEY="$HOME/.ssh/arcadepipe_vps"
SSH_USER="deploy"
SSH_PORT="2222"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/terraform"
DOCKER_DIR="$SCRIPT_DIR/docker"
TAR_PATH="/tmp/${STACK}-deploy.tar.gz"

# Exécute la commande, ou l'affiche en --dry-run. Les commandes en lecture
# seule (tofu output, docker compose config, docker image inspect) tournent
# quand même en dry-run.
run() {
  if $DRY_RUN; then
    printf '[dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

HOST="$(cd "$TERRAFORM_DIR" && tofu output -raw server_ip)"

echo "== Déploiement de '$STACK' sur $HOST $($DRY_RUN && echo '(dry-run — rien ne sera modifié)') =="

# traefik-public est partagé par toutes les stacks (external: true) : créé ici, idempotent.
run ssh -n -p "$SSH_PORT" -i "$SSH_KEY" "$SSH_USER@$HOST" "docker network create traefik-public 2>/dev/null || true"

run tar -czf "$TAR_PATH" -C "$DOCKER_DIR" "$STACK"
run scp -P "$SSH_PORT" -i "$SSH_KEY" "$TAR_PATH" "$SSH_USER@$HOST:~/${STACK}.tar.gz"
$DRY_RUN || rm -f "$TAR_PATH"

run ssh -n -p "$SSH_PORT" -i "$SSH_KEY" "$SSH_USER@$HOST" "tar xzf ~/${STACK}.tar.gz && rm ~/${STACK}.tar.gz"

# Snapshot :previous des images CONSTRUITES localement (services avec "build:",
# soit portal) avant de reconstruire : retour arrière en une commande
# (`docker tag IMAGE:previous IMAGE:latest && docker compose up -d`). Les images
# tirées (traefik, docker-socket-proxy) se fixent dans docker-compose.yml.
# ATTENTION : `docker image prune -a` supprimerait aussi un ":previous" non
# utilisé — ne jamais l'employer sur ce VPS ; `prune` sans -a l'épargne.
BUILT_SERVICES="$(awk '
  /^  [a-zA-Z0-9_-]+:$/ { svc=$1; sub(":$","",svc) }
  /^    build:/ { print svc }
' "$DOCKER_DIR/$STACK/docker-compose.yml" | sort -u | tr '\n' ' ')"

if [ -z "$BUILT_SERVICES" ]; then
  echo "-- Aucune image construite localement dans '$STACK' : snapshot :previous ignoré --"
else
  echo "-- Snapshot :previous ($BUILT_SERVICES) --"
  IMAGES="$(ssh -n -p "$SSH_PORT" -i "$SSH_KEY" "$SSH_USER@$HOST" "cd ~/$STACK && docker compose config --images $BUILT_SERVICES" 2>/dev/null || true)"
  for img in $IMAGES; do
    if ssh -n -p "$SSH_PORT" -i "$SSH_KEY" "$SSH_USER@$HOST" "docker image inspect '$img' >/dev/null 2>&1"; then
      base="${img%:*}"
      run ssh -n -p "$SSH_PORT" -i "$SSH_KEY" "$SSH_USER@$HOST" "docker tag '$img' '$base:previous'"
      echo "snapshot : $img -> $base:previous"
    fi
  done
fi

# pull avant up : arcadepipe n'a que des "image:" (GHCR) ; sans pull, `up --build`
# réutiliserait l'image locale même périmée. Sans effet pour traefik/portal.
run ssh -n -p "$SSH_PORT" -i "$SSH_KEY" "$SSH_USER@$HOST" "cd ~/$STACK && docker compose pull && docker compose up -d --build"

# Garde :latest et :previous : `prune -f` (sans -a) ne supprime que les images sans tag.
echo "-- Nettoyage des images orphelines --"
run ssh -n -p "$SSH_PORT" -i "$SSH_KEY" "$SSH_USER@$HOST" "docker image prune -f"

if $DRY_RUN; then
  echo
  echo "== Dry-run terminé : rien n'a été transféré, construit ou démarré =="
  exit 0
fi

# Attend que les conteneurs ne soient plus "starting"/"unhealthy" (30 s max, toutes
# les 2 s) plutôt qu'un délai fixe, qui donnerait un faux ❌ pendant un start_period.
ATTENTE=0
while [ "$ATTENTE" -lt 30 ]; do
  PAS_PRET="$(ssh -n -p "$SSH_PORT" -i "$SSH_KEY" "$SSH_USER@$HOST" "cd ~/$STACK && docker compose ps --format '{{.Status}}'" 2>/dev/null | grep -iE 'starting|unhealthy' || true)"
  [ -z "$PAS_PRET" ] && break
  sleep 2
  ATTENTE=$((ATTENTE + 2))
done

STATUT="$(ssh -n -p "$SSH_PORT" -i "$SSH_KEY" "$SSH_USER@$HOST" "cd ~/$STACK && docker compose ps --format 'table {{.Name}}\t{{.Status}}'")"

# Le statut Docker est le signal fiable (PAS_PRET non vide = délai de 30 s dépassé).
# Chercher "error" dans les logs de Traefik a été abandonné : une course de
# démarrage bénigne (docker-socket-proxy pas encore prêt) laisse toujours une
# ligne d'erreur, donc un ❌ permanent.
ECHEC=false
[ -n "$PAS_PRET" ] && ECHEC=true

case "$STACK" in
  traefik)
    ERREURS="$(ssh -n -p "$SSH_PORT" -i "$SSH_KEY" "$SSH_USER@$HOST" "docker logs traefik-traefik-1 --tail 10 2>&1")"
    ;;
  portal)
    CODE_GAME="$(curl -sS -o /dev/null -w '%{http_code}' "https://game.pazpop.net/" || echo '???')"
    [ "$CODE_GAME" = "200" ] || ECHEC=true
    ;;
  arcadepipe)
    CODE_SITE="$(curl -sS -o /dev/null -w '%{http_code}' "https://arcadepipe.pazpop.net/" || echo '???')"
    CODE_API="$(curl -sS -o /dev/null -w '%{http_code}' "https://arcadepipe.pazpop.net/api/health" || echo '???')"
    [ "$CODE_SITE" = "200" ] || ECHEC=true
    [ "$CODE_API" = "200" ] || ECHEC=true
    ;;
esac

echo
echo "===================== Résumé ====================="
echo "$STATUT"
echo "----------------------------------------------------"
case "$STACK" in
  traefik)
    if [ -z "$PAS_PRET" ]; then
      echo "Conteneurs        : ✅ tous prêts"
    else
      echo "Conteneurs        : ❌ toujours pas prêts après 30s"
    fi
    echo "Derniers logs Traefik (informatif, ne détermine pas le succès) :"
    echo "$ERREURS"
    ;;
  portal)
    if [ "$CODE_GAME" = "200" ]; then
      echo "game.pazpop.net   : ✅ $CODE_GAME"
    else
      echo "game.pazpop.net   : ❌ $CODE_GAME"
    fi
    ;;
  arcadepipe)
    [ "$CODE_SITE" = "200" ] && echo "arcadepipe.pazpop.net      : ✅ $CODE_SITE" || echo "arcadepipe.pazpop.net      : ❌ $CODE_SITE"
    [ "$CODE_API" = "200" ] && echo "arcadepipe.pazpop.net/api  : ✅ $CODE_API" || echo "arcadepipe.pazpop.net/api  : ❌ $CODE_API"
    ;;
esac
echo "===================================================="

$ECHEC && exit 1
exit 0
