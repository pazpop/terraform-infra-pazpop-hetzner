# terraform-infra-pazpop-hetzner

Infra du VPS Hetzner qui héberge [ArcadePipe](https://github.com/pazpop/arcadepipe) (et, à terme, d'autres jeux du même genre). Gérée avec [OpenTofu](https://opentofu.org/) plutôt que Terraform (fork open-source, même langage HCL, aucune dépendance à HashiCorp).

## 🎓 Contexte

Ce projet est réalisé avec l'aide de [Claude](https://claude.com) (Anthropic) comme assistant technique. L'objectif n'est pas de contourner l'apprentissage, mais de l'accélérer : explorer des choix que je n'aurais pas eu le temps de creuser seul, challenger mes propres habitudes, et accélérer les tâches répétitives. Je reste le décideur à chaque étape — je teste avant de faire confiance, je demande des revues de sécurité et de qualité, et j'écarte ce qui est disproportionné pour un projet de cette taille (voir *Sécurité* et *Choix délibérés* ci-dessous, qui documentent aussi bien ce qui est fait que ce qui est volontairement laissé de côté, et pourquoi). L'IA ne remplace pas l'expertise, elle en démultiplie la portée.

## Stack

| Composant | Techno | Rôle |
|---|---|---|
| Cloud provider | [Hetzner Cloud](https://www.hetzner.com/cloud/) (`hcloud`) | VPS `cx23`, IP primaire, firewall |
| Provisioning initial | cloud-init | Installe Docker au premier boot |
| Reverse proxy | [Traefik](https://traefik.io/) (`traefik/`) | Point d'entrée public 80/443, TLS auto (Let's Encrypt), routage par labels Docker — mutualisé entre jeux |
| Portail | Page statique auto-générée (`portal/`) | `game.pazpop.net` liste les jeux déployés (chacun sur son propre sous-domaine, ex: `arcadepipe.pazpop.net`), à partir des labels `pazpop.portal.*` — rien à modifier à la main pour ajouter/retirer un jeu |
| Jeux | `arcadepipe/` (docker-compose.yml) | Déploiement de [ArcadePipe](https://github.com/pazpop/arcadepipe) (code/CI dans son propre repo public) — ce dossier-ci ne contient que le routage Traefik + les limites de ressources, pas le code du jeu |
| État Terraform | Local (`terraform.tfstate`, gitignoré) | Un seul opérateur, une seule VPS — pas de backend distant, voir *Choix délibérés* |

## Fichiers

```
terraform.tf     # bloc terraform{} : version, provider requis
provider.tf      # bloc provider "hcloud"
variables.tf     # toutes les variables d'entrée
main.tf          # ressources : clé SSH, firewall, IP, serveur
outputs.tf       # IP du serveur, commande SSH prête à l'emploi
cloud-init.yaml  # exécuté au premier boot du VPS (installe Docker)
deploy.sh        # déploie une stack (traefik, portal ou arcadepipe) sur le VPS — tar/scp/ssh/pull/up
traefik/         # stack Traefik — se déploie à part, pas via tofu apply (voir traefik/README.md)
portal/          # page d'accueil auto-générée listant les jeux déployés (voir portal/README.md)
arcadepipe/      # docker-compose.yml (routage Traefik) pour github.com/pazpop/arcadepipe — voir CI/CD
```

## Utilisation

Prérequis : [OpenTofu](https://opentofu.org/docs/intro/install/) installé, un [token API Hetzner](https://console.hetzner.cloud/) (scope Read & Write), une paire de clés SSH dédiée.

```sh
cp terraform.tfvars.example terraform.tfvars   # renseigner hcloud_token + ssh_source_cidrs
tofu init
tofu plan
tofu apply
```

`terraform.tfvars` est gitignoré (il contient le token) — ne jamais le committer.

Ensuite, sur le VPS, dans l'ordre : `./deploy.sh traefik` (crée le réseau `traefik-public`, voir `traefik/README.md`), puis `./deploy.sh portal` (`portal/README.md`), puis `./deploy.sh arcadepipe` (voir *CI/CD* ci-dessous pour le déploiement automatique) — chaque jeu rejoint `traefik-public` et pose ses labels `pazpop.portal.*` pour apparaître automatiquement sur le portail.

La sortie `ssh_command` (`tofu output ssh_command`) donne la commande prête à l'emploi.

## CI/CD — déploiement d'ArcadePipe

Le code et le build d'ArcadePipe vivent dans son propre repo public
([`pazpop/arcadepipe`](https://github.com/pazpop/arcadepipe)) : son CI build
et publie les images sur GHCR à chaque push sur `main`, puis déclenche un
événement `repository_dispatch` vers **ce repo-ci**, qui reçoit l'événement
(`.github/workflows/deploy-arcadepipe.yml`) et fait le déploiement SSH réel
(synchronise `arcadepipe/docker-compose.yml`, `docker compose pull && up -d`
sur la VPS). Le code du jeu ne connaît jamais l'IP du VPS ni les détails de
Traefik ; ce repo-ci ne connaît jamais le code du jeu.

Secrets à configurer :
- **Dans `pazpop/terraform-infra-pazpop-hetzner`** (ce repo) : `DEPLOY_HOST`, `DEPLOY_USER`, `DEPLOY_SSH_KEY` — la connexion SSH vers la VPS, utilisée par `deploy-arcadepipe.yml`.
- **Dans `pazpop/arcadepipe`** : un secret `TERRAFORM_INFRA_DISPATCH_TOKEN` — un [personal access token *fine-grained*](https://github.com/settings/tokens?type=beta) avec accès à ce repo (`terraform-infra-pazpop-hetzner`) uniquement, permission **Contents: Read and write** (requise par `repository_dispatch`). C'est ce qui permet au CI du jeu de déclencher un déploiement ici sans avoir un accès plus large à ce compte.

Redéploiement manuel possible à tout moment sans rien pousser, depuis l'onglet *Actions* de ce repo → `Deploy ArcadePipe` → *Run workflow* (utile pour un rollback ou pour retenter après un échec transitoire).

## Sécurité

- SSH restreint par IP source (`ssh_source_cidrs`) — ouvert par défaut (`0.0.0.0/0`) tant que non renseigné, voir le commentaire dans `variables.tf` pour se restreindre.
- Seuls 22 (SSH), 80 et 443 (HTTP/HTTPS, publics par nature) sont ouverts par le firewall Hetzner.
- Token Hetzner marqué `sensitive` dans Terraform, jamais commité (`.gitignore`).
- IP primaire détachée du cycle de vie du serveur (`auto_delete = false`) : recréer le VPS ne change jamais l'IP publique, donc jamais besoin de mettre à jour le DNS dans l'urgence.
- Traefik et le portail n'ont jamais d'accès direct à `/var/run/docker.sock` : ils passent par `docker-socket-proxy` (lecture seule, restreint aux endpoints nécessaires) — voir `traefik/README.md` et `portal/README.md`.
- VPS rebooté systématiquement en fin de provisioning (`cloud-init.yaml`), après mises à jour système et installation de Docker — garantit un noyau à jour et un état propre avant tout déploiement.
- `Content-Security-Policy` sur le middleware `secure-headers` (`traefik/dynamic/middlewares.yml`), appliquée à tous les jeux/portail routés par Traefik. `'unsafe-eval'` requis pour `lib/libopenmpt.js` (arcadepipe, asm.js généré par Emscripten) ; `'unsafe-inline'` sur `style-src` requis pour le `<style>` inline généré par le portail. Testé en réel (navigateur, sites en direct) : zéro violation, zéro régression.

## Choix délibérés

- **Pas de backend d'état distant** (S3/GCS) : un seul opérateur, une seule VPS, l'enjeu d'un état local perdu est faible — ajouter un bucket cloud pour ça serait de la complexité inutile pour ce projet. À reconsidérer si plusieurs personnes ou machines doivent un jour appliquer les mêmes changements.
- **Traefik hors Terraform** : c'est une stack Docker Compose applicative (comme les jeux qu'elle route), pas une ressource d'infra Hetzner — elle se déploie manuellement sur le VPS, cohérent avec la façon dont les jeux eux-mêmes sont déployés.

## Licence

[MIT](LICENSE).
