# Pas de contenu copié ici : index.html vient du volume partagé
# portal_html, écrit par le conteneur "generator" (voir docker-compose.yml).
FROM caddy:2.11.4-alpine@sha256:6aeddd44c3078b0f9a35206472a11420648a79c184603ef95957d0a20044cb2b

COPY Caddyfile /etc/caddy/Caddyfile

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s \
  CMD wget --spider -q http://localhost:80/ || exit 1
