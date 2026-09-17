# Image jetable minimaliste (~10 Mo) : juste sqlite3, rien d'autre. Construite
# et utilisée localement sur la VPS (voir deploy-backup.sh) — jamais publiée
# sur un registre. Choisie plutôt qu'une image tierce toute faite (ex:
# keinos/sqlite3, pourtant légitime et maintenue) : sur le chemin de
# restauration d'une panne, mieux vaut dépendre d'une image qu'on construit
# soi-même en 2 lignes que d'une dépendance externe qui pourrait avoir
# disparu ou changé le jour où on en a besoin.
#
# Épinglée par digest (pas par tag "3.20") — même raisonnement que les
# Dockerfiles d'arcadepipe : un tag est une référence mobile, un digest ne
# change jamais pour un contenu donné. Dependabot (.github/dependabot.yml,
# écosystème "docker") ouvre une PR de bump de digest automatiquement.
FROM alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc

RUN apk add --no-cache sqlite
