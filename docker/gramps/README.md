# Gramps Web (arbre généalogique)

[Gramps Web](https://www.grampsweb.org/) sur `https://<GRAMPS_DOMAIN>`, derrière Traefik. Stack Docker Compose indépendante de Terraform, déployée avec `./deploy.sh gramps` comme les autres.

Le contenu de l'arbre ne vit **jamais** dans ce repo (public) : il est dans les volumes Docker du VPS, sauvegardé par `backup/backup-gramps.sh`, et exporté vers le repo privé `arbre-genealogique`. L'outillage côté utilisateur (export, synchronisation, procédures) est dans le repo `gramps-web`.

## Architecture

```
Internet ──443──> Traefik ──(traefik-public)──> grampsweb :5000 (API + interface, gunicorn x2)
                                                   │
                                          (gramps-internal)
                                                   │
                                   gramps-celery (imports, exports, index) ── gramps-redis (Valkey, file de tâches)
```

| Service | Rôle | Réseaux | Mémoire max |
|---|---|---|---|
| `grampsweb` | API et interface web | `traefik-public`, `gramps-internal` | 1,5 Go |
| `gramps-celery` | Tâches longues (import GEDCOM, export, index de recherche) | `gramps-internal` | 1 Go |
| `gramps-redis` | File Celery et compteurs du rate-limit, rien de persistant | `gramps-internal` | 64 Mo |

Volumes nommés explicitement (`gramps_db`, `gramps_users`, `gramps_media`, `gramps_secret`, …), pour que le backup les trouve quel que soit le nom du dossier de déploiement.

## Choix de sécurité

- **Pas exposé au premier déploiement** (`GRAMPS_EXPOSE=false`) : tant qu'aucun compte n'existe, Gramps Web affiche un assistant de premier démarrage qui laisse **n'importe quel visiteur** créer le compte propriétaire. On le crée donc en ligne de commande avant d'ouvrir la route.
- **Inscription fermée** (`GRAMPSWEB_REGISTRATION_DISABLED`), **télémétrie coupée**, **absent du portail** `game.pazpop.net`, en-tête `X-Robots-Tag: noindex`.
- **Aucun secret en `environment:`** (lisible via `docker-socket-proxy`, voir `docker/traefik/README.md`) : la clé Flask est générée par l'image dans le volume `gramps_secret` ; un mot de passe SMTP irait dans `config.cfg`, fichier monté en lecture seule et gitignoré.
- **Middlewares dédiés** (`docker/traefik/dynamic/middlewares.yml`) : `gramps-headers` (les en-têtes de `secure-headers` sans sa CSP, taillée pour arcadepipe) et `gramps-rate-limit` (burst 200 : une page charge des dizaines de vignettes). Le login (`/api/token/`) a en plus son propre routeur avec `gramps-login-limit` (5 essais/min par IP, vue par Traefik) : la limite interne de Gramps Web (1/s) ne voit que l'IP de Traefik, donc elle est commune à tous les visiteurs.
- **Version épinglée** de l'image, mise à jour par PR Dependabot, jamais automatiquement déployée.

## Premier déploiement

Prérequis : Traefik déployé (`./deploy.sh traefik`), et un enregistrement DNS A `GRAMPS_DOMAIN` vers l'IP du VPS (`tofu output server_ip`).

```sh
cd docker/gramps
cp .env.example .env           # GRAMPS_DOMAIN, GRAMPS_TREE ; laisser GRAMPS_EXPOSE=false
cp config.cfg.example config.cfg
cd ../..
./deploy.sh gramps             # tire l'image (plusieurs Go la première fois), démarre, sans route publique
```

Au tout premier démarrage, `grampsweb` et `gramps-celery` créent chacun l'arbre s'il n'existe pas : en parallèle, on peut obtenir **deux arbres du même nom**. Vérifier, et figer l'identifiant :

```sh
docker exec gramps-grampsweb-1 python3 -m gramps_webapi tree list   # un seul arbre attendu
```

S'il y en a deux : `docker compose down`, supprimer les volumes `gramps_db` et `gramps_index` (tout est vide à ce stade), relancer `docker compose up -d grampsweb`, attendre qu'il réponde, puis `docker compose up -d`. Dans les deux cas, reporter l'identifiant affiché dans le `.env` local, `docker/gramps/.env` (`GRAMPS_TREE_ID=…` ; celui du VPS est remplacé à chaque déploiement) : le nom devient alors modifiable sans risque.

Créer le compte propriétaire (rôle 4) sur le VPS. `read -s` évite que le mot de passe finisse dans l'historique du shell. Il reste visible quelques secondes dans la commande du conteneur temporaire (`ps`, API Docker) : acceptable tant que la route n'est pas ouverte, mais **change ce mot de passe dans l'interface** une fois connecté.

```sh
ssh -i ~/.ssh/arcadepipe_vps -p 2222 deploy@<IP>
cd ~/gramps
read -rsp "Mot de passe : " PW; echo
docker compose run --rm grampsweb python3 -m gramps_webapi user add <utilisateur> "$PW" --fullname "<Nom>" --role 4
unset PW
```

Puis ouvrir la route : `GRAMPS_EXPOSE=true` dans `docker/gramps/.env`, et `./deploy.sh gramps` de nouveau (le résumé doit afficher ✅ en face du domaine).

Enfin, installer le backup : `cd backup && ./deploy-backup.sh`.

Le contenu de l'arbre (import, restauration depuis Git) relève du repo `gramps-web`.

## Rôles utiles

| Rôle | N° | Pour qui |
|---|---|---|
| Propriétaire (Owner) | 4 | Toi |
| Éditeur (Editor) | 3 | Quelqu'un qui corrige l'arbre |
| Contributeur (Contributor) | 2 | Ajoute sans modifier l'existant |
| Membre (Member) | 1 | Consultation, y compris les fiches privées |
| Invité (Guest) | 0 | Consultation sans les fiches privées |

Ajouter un compte : Administration ▸ Utilisateurs, ou la même commande `user add` avec `--role`.

## Backup et restauration

Backup quotidien à 3h30 (`backup/backup-gramps.sh`, timer systemd) dans `/var/backups/gramps/{daily,weekly}` (7 + 4 archives, dossier en `700`) : bases SQLite de l'arbre et des comptes (copiées par `.backup`, vérifiées par `integrity_check`), clé Flask, médias. Backup **local** seulement, comme arcadepipe : une copie distante est prioritaire ici, l'arbre ne se reconstruit pas.

L'export Gramps XML (`.gramps`), sans perte et portable, reste la vraie sauvegarde « hors VPS » : le script d'export du repo `gramps-web` le dépose dans `arbre-genealogique`.

Restauration **non testée à ce jour** (à faire avant d'y mettre des données qu'on ne veut pas perdre) :

```sh
cd ~/gramps && docker compose stop grampsweb gramps-celery
mkdir /tmp/restore && tar -xzf /var/backups/gramps/daily/gramps_AAAA-MM-JJ_HHMM.tar.gz -C /tmp/restore
docker run --rm -v gramps_db:/dst/db -v gramps_users:/dst/users -v gramps_secret:/dst/secret \
  -v gramps_media:/dst/media -v /tmp/restore:/src backup-tool sh -euc '
    rm -rf /dst/db/* /dst/users/* /dst/secret/* /dst/media/*
    cp -a /src/db/. /dst/db/ && cp -a /src/users/. /dst/users/ && cp -a /src/secret/. /dst/secret/
    tar -C /dst -xf /src/media.tar'
docker compose up -d
docker compose exec grampsweb python3 -m gramps_webapi search index-full   # reconstruit l'index de recherche
rm -rf /tmp/restore
```

Autre voie, plus simple : Administration ▸ Données ▸ **Restaurer depuis une sauvegarde** avec un export `.gramps` (remplace l'arbre ; les médias ne sont pas inclus).

## Mise à jour de Gramps Web

1. PR Dependabot (nouvelle version de `ghcr.io/gramps-project/grampsweb`) : lire les notes de version (migrations de base).
2. Vérifier la présence d'un backup de la nuit, ou en lancer un : `sudo systemctl start gramps-backup.service`.
3. Fusionner, puis `./deploy.sh gramps`.

## Roadmap

- [ ] Tester la restauration de bout en bout (comme `backup/test-backup-restore.sh` pour arcadepipe).
- [ ] Copie distante des backups (rclone), prioritaire pour ces données.
- [ ] CSP propre à Gramps Web : observer la console du navigateur (cartes, vignettes, polices), puis l'ajouter à `gramps-headers`. Pas de valeur devinée.
- [ ] `cap_drop: ALL` sur `grampsweb` et `gramps-celery` : l'image tourne en root et écrit dans ses volumes ; à essayer puis vérifier import, export et médias avant de l'adopter.
- [ ] Option : restreindre l'accès à certaines IP (middleware `ipAllowList`) ou passer par un VPN, si l'arbre n'a pas besoin d'être joignable de partout.
