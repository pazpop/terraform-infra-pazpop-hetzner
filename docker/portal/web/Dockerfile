# Pas de contenu copié ici : index.html vient du volume partagé
# portal_html, écrit par le conteneur "generator" (voir docker-compose.yml).
FROM caddy:2.11.7-alpine@sha256:d8542f48d34a9cf4e4c11a478865229840e87e4c96ea3f439101f31a5d35f75f

COPY Caddyfile /etc/caddy/Caddyfile

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s \
  CMD wget --spider -q http://localhost:80/ || exit 1
