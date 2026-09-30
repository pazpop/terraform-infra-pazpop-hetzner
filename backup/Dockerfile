# Image jetable "backup-tool" (~10 Mo) : sqlite3 seulement, construite sur la VPS
# par deploy-backup.sh, jamais publiée. Construite soi-même plutôt qu'une image
# tierce : sur le chemin d'une restauration, mieux vaut ne pas en dépendre.
# Épinglée par digest (Dependabot ouvre les PR de mise à jour).
FROM alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6

RUN apk add --no-cache sqlite
