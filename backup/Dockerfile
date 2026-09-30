# Image jetable (~10 Mo) : sqlite3 seulement, construite localement sur la VPS
# (deploy-backup.sh), jamais publiée. Construite soi-même plutôt qu'une image
# tierce : sur le chemin d'une restauration, mieux vaut ne pas en dépendre.
# Épinglée par digest (Dependabot ouvre les PR de mise à jour).
FROM alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc

RUN apk add --no-cache sqlite
