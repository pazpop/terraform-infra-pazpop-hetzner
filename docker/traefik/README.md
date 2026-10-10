# Traefik (reverse-proxy partagé)

Stack indépendante de Terraform — se déploie manuellement sur la VPS (comme les apps), pas via `tofu apply`.

## Déploiement / bootstrap

Depuis la racine du dépôt (`terraform-infra-pazpop-hetzner/`) :

```sh
./deploy.sh traefik
```

Crée le réseau `traefik-public` (idempotent), transfère la stack et démarre les conteneurs. Fonctionne aussi bien pour le premier lancement sur une VPS neuve que pour un redéploiement après modification.

Ensuite, chaque stack (`docker/arcadepipe`, `docker/portal`...) rejoint le réseau `traefik-public` et se route par ses labels : rien à modifier dans ce dossier pour en ajouter une. Une nouvelle stack demande en revanche son nom dans la liste acceptée par `deploy.sh`, et sa vérification d'adresse à la fin du script.

`./deploy.sh traefik` recrée Traefik : tous les sites sont coupés quelques secondes.

## Notes

- Seul ce service publie les ports 80/443 sur la VPS.
- `traefik` n'a jamais accès direct à `/var/run/docker.sock` — seulement à `docker-socket-proxy`, restreint à la lecture des conteneurs/réseaux (`CONTAINERS=1`, `NETWORKS=1`, voir le commentaire dans `docker-compose.yml`). Même pattern que `portal/generator` (voir `portal/README.md`).
- **`CONTAINERS=1` expose plus qu'un simple statut « en ligne / hors ligne ».** `GET /containers/{id}/json` renvoie `Config.Env`, la liste complète des variables d'environnement de n'importe quel conteneur du serveur. Qui compromettrait Traefik ou le générateur du portail pourrait donc les lire. **Règle : aucun secret dans une variable d'environnement** (`environment:` comme `env_file`, qui revient au même) : un secret va dans un fichier monté, comme `config.cfg` pour Gramps, ou dans un secret Docker.
- Certificats Let's Encrypt (HTTP-01, port 80) stockés dans le volume nommé `letsencrypt`.
- Dashboard Traefik désactivé (pas d'exposition publique).
- Le middleware d'en-têtes de sécurité partagé est dans `dynamic/middlewares.yml` (`secure-headers`) — à référencer depuis les labels de chaque app.
