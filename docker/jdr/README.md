# jdr

Aide de jeu de rôle du meneur, sur `jdr.pazpop.net` : ses pages derrière un mot de passe, et l'écran des joueurs, que chacun ouvre sans mot de passe par un lien à lui.

Le site vit dans un autre dépôt, privé : `github.com/pazpop/jdr_co-cthulhu`. Son CI construit l'image `ghcr.io/pazpop/jdr_co-cthulhu` (privée elle aussi) à chaque push, puis déclenche ici `.github/workflows/deploy-jdr.yml`. Ce dossier ne contient que le routage.

## Mise en place (une fois)

Prérequis : Traefik déployé, et un enregistrement DNS `A` pour `jdr.pazpop.net`.

1. **Jeton de lecture pour le VPS.** L'image est privée : sur GitHub, *Settings > Developer settings > Personal access tokens > Tokens (classic)*, créer un jeton avec la seule permission `read:packages`. Puis, sur le VPS :
   ```sh
   docker login ghcr.io -u pazpop      # coller le jeton comme mot de passe
   ```
   Docker le garde dans `~/.docker/config.json` du compte `deploy`.
2. **Secret du dépôt `jdr_co-cthulhu`** : `TERRAFORM_INFRA_DISPATCH_TOKEN`, le même jeton que celui du dépôt `arcadepipe` (voir [docs/ci-cd.md](../../docs/ci-cd.md)).
3. **Mot de passe du site**, puis premier déploiement, depuis ce dépôt :
   ```sh
   cp docker/jdr/.env.example docker/jdr/.env   # identifiant et empreinte du mot de passe
   ./deploy.sh jdr
   ```

Ensuite, chaque push sur `main` de `jdr_co-cthulhu` déploie tout seul. `./deploy.sh jdr` ne sert plus qu'à changer le mot de passe.

## Notes

- Sans identifiants, tout répond 401, sauf `/sante` (que `deploy.sh` interroge à la fin), la page `ecran.html` et les adresses `/direct/...` de l'écran des joueurs.
- `.env` doit contenir l'identifiant **et** l'empreinte : avec une empreinte vide, le conteneur ne démarre pas.
- **Changer le mot de passe change les liens des joueurs** et leurs codes QR : ils sont calculés à partir de son empreinte.
- Un déploiement redémarre le conteneur : les écrans des joueurs se vident (leurs liens restent bons). Pas de déploiement pendant une partie.
- L'écran des joueurs ne répond plus alors que l'aide marche : sur le VPS, `cd ~/jdr && docker compose restart`.
- Pas de sauvegarde : le site ne garde aucune donnée, tout est dans son dépôt.
- Absent du portail `game.pazpop.net`, volontairement : pas de label `pazpop.portal.*`.
