# Portail (page d'accueil des apps)

Page HTML minimale sur `game.pazpop.net` qui liste les applications déployées sur la VPS, générée automatiquement à partir des labels Docker — pas de fichier à modifier à la main quand une app arrive ou repart.

Comme `traefik/`, stack indépendante de Terraform, se déploie manuellement sur la VPS.

## Fonctionnement

```
docker-socket-proxy  --(GET /containers, lecture seule)-->  generator  --(écrit)-->  volume partagé  --(sert)-->  web (Caddy)  --(Traefik)-->  game.pazpop.net
```

`generator` régénère `index.html` toutes les 30s à partir des conteneurs portant les labels :

```yaml
labels:
  - "pazpop.portal.enable=true"
  - "pazpop.portal.name=ArcadePipe"
  - "pazpop.portal.url=https://arcadepipe.pazpop.net"
```

Pour ajouter un nouveau jeu au portail : mettre ces 3 labels sur son service Docker public-facing (un seul par app, pas sur chaque conteneur si l'app en a plusieurs) — rien à toucher ici.

## Déploiement / bootstrap (après le stack Traefik)

Depuis la racine du dépôt (`terraform-infra-pazpop-hetzner/`) :

```sh
./deploy.sh portal
```

Transfère la stack, construit et démarre les conteneurs, vérifie `game.pazpop.net`. Fonctionne aussi bien pour le premier lancement que pour un redéploiement après modification.

## Notes

- `generator` n'a jamais accès direct à `/var/run/docker.sock` — seulement à `docker-socket-proxy`, restreint à `GET /containers` (voir le commentaire dans `docker-compose.yml`).
- Aucune donnée utilisateur, aucun tracker — le contenu de la page vient uniquement des labels que nous posons nous-mêmes sur nos propres conteneurs.

## Roadmap

- [ ] Durcir `web` comme `generator`/`docker-socket-proxy` (`cap_drop: ALL`, rootfs read-only, non-root) — nécessite une image Caddy custom (même limite que le frontend d'arcadepipe, simple serveur de fichiers statiques)
