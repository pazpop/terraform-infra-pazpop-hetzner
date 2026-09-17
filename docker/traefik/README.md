# Traefik (reverse-proxy partagé)

Stack indépendante de Terraform — se déploie manuellement sur la VPS (comme les apps), pas via `tofu apply`.

## Configuration

```sh
cp .env.example .env   # renseigner ACME_EMAIL (email de contact Let's Encrypt)
```

`.env` est gitignoré — jamais committé.

## Déploiement / bootstrap

Depuis la racine du dépôt (`terraform-infra-pazpop-hetzner/`) :

```sh
./deploy.sh traefik
```

Crée le réseau `traefik-public` (idempotent), transfère la stack, construit et démarre les conteneurs, vérifie les logs. Fonctionne aussi bien pour le premier lancement sur une VPS neuve que pour un redéploiement après modification.

Ensuite, chaque repo d'app (ex: `arcadepipe`) rejoint le réseau `traefik-public` et se route via labels — rien à modifier ici pour ajouter un nouveau jeu.

## Notes

- Seul ce service publie les ports 80/443 sur la VPS.
- `traefik` n'a jamais accès direct à `/var/run/docker.sock` — seulement à `docker-socket-proxy`, restreint à la lecture des conteneurs/réseaux (`CONTAINERS=1`, `NETWORKS=1`, voir le commentaire dans `docker-compose.yml`). Même pattern que `portal/generator` (voir `portal/README.md`).
- **`CONTAINERS=1` expose plus qu'un simple statut "en ligne/hors ligne".** Vérifié en réel : `GET /containers/{id}/json` via ce proxy renvoie `Config.Env`, la liste **complète** des variables d'environnement du conteneur interrogé — pas seulement celui qui fait la requête. Concrètement : n'importe quel service qui a accès au réseau `traefik-internal` peut lire les `environment:` de n'importe quel conteneur exposé à Traefik (`traefik.enable=true`), pas seulement les siens. **Règle : jamais de secret dans `environment:` d'un service qui rejoint `traefik-public`/`traefik-internal`** — utiliser un fichier monté (`env_file` pointant vers un fichier non commité, ou un secret Docker) pour tout ce qui doit rester confidentiel.
- Certificats Let's Encrypt (HTTP-01, port 80) stockés dans le volume nommé `letsencrypt`.
- Dashboard Traefik désactivé (pas d'exposition publique).
- Le middleware d'en-têtes de sécurité partagé est dans `dynamic/middlewares.yml` (`secure-headers`) — à référencer depuis les labels de chaque app.
- La version de l'image `traefik` dans `docker-compose.yml` doit rester ≥ v3.6.1 : les versions antérieures négocient une API Docker figée à 1.24, insuffisante pour Docker ≥ 29 (minimum relevé à 1.44).
