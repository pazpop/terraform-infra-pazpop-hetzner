# Pas de contenu copié ici : index.html vient du volume partagé
# portal_html, écrit par le conteneur "generator" (voir docker-compose.yml).
FROM caddy:2-alpine

COPY Caddyfile /etc/caddy/Caddyfile

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s \
  CMD wget --spider -q http://localhost:80/ || exit 1
