#!/usr/bin/env bash
# Déploie une stack Docker Compose (traefik, portal ou arcadepipe) sur le VPS.
# Remplace la séquence manuelle tar/scp/ssh — mêmes commandes, juste
# regroupées pour ne pas en oublier une pendant un vrai incident.
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

# Exécute la commande normalement, ou l'affiche sans l'exécuter en --dry-run.
# Les commandes en lecture seule (tofu output, docker compose config
# --images, docker image inspect) tournent quand même en dry-run : elles ne
# modifient rien et donnent un aperçu fidèle de ce qui serait fait.
run() {
  if $DRY_RUN; then
    printf '[dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

HOST="$(cd "$TERRAFORM_DIR" && tofu output -raw server_ip)"

echo "== Déploiement de '$STACK' sur $HOST $($DRY_RUN && echo '(dry-run — rien ne sera modifié)') =="

# traefik-public est partagé entre traefik/portal/arcadepipe et n'est créé
# par aucune des stacks (external: true dans chaque docker-compose.yml) —
# idempotent, sans effet si déjà présent.
run ssh -n -p "$SSH_PORT" -i "$SSH_KEY" "$SSH_USER@$HOST" "docker network create traefik-public 2>/dev/null || true"

run tar -czf "$TAR_PATH" -C "$DOCKER_DIR" "$STACK"
run scp -P "$SSH_PORT" -i "$SSH_KEY" "$TAR_PATH" "$SSH_USER@$HOST:~/${STACK}.tar.gz"
$DRY_RUN || rm -f "$TAR_PATH"

run ssh -n -p "$SSH_PORT" -i "$SSH_KEY" "$SSH_USER@$HOST" "tar xzf ~/${STACK}.tar.gz && rm ~/${STACK}.tar.gz"

# Snapshot des images CONSTRUITES localement par cette stack en :previous,
# AVANT de reconstruire — permet de revenir en arrière d'une commande
# (`docker tag IMAGE:previous IMAGE:latest && docker compose up -d`) si le
# nouveau déploiement pose problème. Ne concerne que les stacks avec un
# Dockerfile (portal) : retaguer une image officielle tirée telle quelle
# (traefik, docker-socket-proxy...) n'aiderait à rien pour un rollback — la
# version de ces images-là se fixe dans docker-compose.yml, pas ici.
#
# ATTENTION : un tag seul ne protège PAS de `docker image prune -a` (qui
# supprime toute image non utilisée par un conteneur en cours, taguée ou
# pas) — seul `docker image prune` (sans -a) épargne les images taguées. Ne
# jamais lancer `-a` sur ce VPS sans vérifier d'abord que ça ne visera pas
# un ":previous" que tu voudrais garder.
# Services qui déclarent "build:" dans le docker-compose.yml de la stack
# (et eux seuls) — pas simplement "un Dockerfile existe quelque part dans le
# dossier", qui inclurait à tort une image tirée comme docker-socket-proxy.
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

# pull avant build : indispensable pour arcadepipe (aucun service "build:",
# seulement des "image:" publiées par son propre CI sur GHCR — sans pull
# explicite, `up -d --build` réutiliserait telle quelle l'image déjà
# présente localement sur la VPS, même si une nouvelle version existe sur
# le registre). Sans effet néfaste pour traefik/portal (pull ne fait rien
# de plus pour un service qui a déjà "build:").
run ssh -n -p "$SSH_PORT" -i "$SSH_KEY" "$SSH_USER@$HOST" "cd ~/$STACK && docker compose pull && docker compose up -d --build"

# Ne garder que le running (:latest) et le snapshot (:previous) — nettoie
# les générations plus anciennes, devenues orphelines (sans tag) dès que le
# ":previous" a été déplacé dessus ci-dessus. `docker image prune -f` (sans
# -a) ne supprime QUE les images totalement sans tag : jamais ":latest" ni
# ":previous" tant qu'ils restent tagués, jamais une image utilisée par un
# conteneur en cours.
echo "-- Nettoyage des images orphelines --"
run ssh -n -p "$SSH_PORT" -i "$SSH_KEY" "$SSH_USER@$HOST" "docker image prune -f"

if $DRY_RUN; then
  echo
  echo "== Dry-run terminé : rien n'a été transféré, construit ou démarré =="
  exit 0
fi

# Attend que tous les conteneurs de la stack soient prêts (ni "starting" ni
# "unhealthy" dans leur statut) plutôt qu'un délai fixe — un sleep trop court
# afficherait un faux ❌ pendant qu'un conteneur est encore dans son
# start_period de healthcheck. 30s max, revérifié toutes les 2s.
ATTENTE=0
while [ "$ATTENTE" -lt 30 ]; do
  PAS_PRET="$(ssh -n -p "$SSH_PORT" -i "$SSH_KEY" "$SSH_USER@$HOST" "cd ~/$STACK && docker compose ps --format '{{.Status}}'" 2>/dev/null | grep -iE 'starting|unhealthy' || true)"
  [ -z "$PAS_PRET" ] && break
  sleep 2
  ATTENTE=$((ATTENTE + 2))
done

STATUT="$(ssh -n -p "$SSH_PORT" -i "$SSH_KEY" "$SSH_USER@$HOST" "cd ~/$STACK && docker compose ps --format 'table {{.Name}}\t{{.Status}}'")"

# Le statut Docker (déjà attendu ci-dessus) est le signal fiable — PAS_PRET
# non vide ici veut dire que le délai de 30s a été atteint sans que tout
# passe "healthy". Grep-er les logs pour "error" a été essayé puis abandonné
# pour Traefik : une course de démarrage bénigne (le docker-socket-proxy pas
# encore prêt à la toute première requête) y laisse quasi systématiquement
# une ligne d'erreur, sans qu'aucune ligne de "succès" ne vienne jamais
# l'effacer — ça déclenchait un ❌ permanent après chaque redémarrage frais,
# même quand tout fonctionnait dès la seconde suivante.
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
