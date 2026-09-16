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
| État Terraform | Local (`terraform.tfstate`, gitignoré) | Un seul opérateur, une seule VPS — pas de backend distant, voir *Choix délibérés* |

## Fichiers

```
terraform.tf     # bloc terraform{} : version, provider requis
provider.tf      # bloc provider "hcloud"
variables.tf     # toutes les variables d'entrée
main.tf          # ressources : clé SSH, firewall, IP, serveur
outputs.tf       # IP du serveur, commande SSH prête à l'emploi
cloud-init.yaml  # exécuté au premier boot du VPS (installe Docker)
deploy.sh        # déploie une stack (traefik ou portal) sur le VPS — tar/scp/ssh/build/up
traefik/         # stack Traefik — se déploie à part, pas via tofu apply (voir traefik/README.md)
portal/          # page d'accueil auto-générée listant les jeux déployés (voir portal/README.md)
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

Ensuite, sur le VPS, dans l'ordre : `./deploy.sh traefik` (crée le réseau `traefik-public`, voir `traefik/README.md`), puis `./deploy.sh portal` (`portal/README.md`), puis chaque jeu (ex: `arcadepipe`, son propre `deploy.sh`) qui rejoint `traefik-public` et pose ses labels `pazpop.portal.*` pour apparaître automatiquement sur le portail.

La sortie `ssh_command` (`tofu output ssh_command`) donne la commande prête à l'emploi.

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
