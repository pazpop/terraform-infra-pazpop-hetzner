# Sécurité

## Accès au VPS

- **SSH** sur le port **2222** (moins de bruit de scans), root interdit (`PermitRootLogin no`), mot de passe désactivé : seule la clé, sur le compte `deploy` (sudo NOPASSWD, groupe `docker`).
- **Ouvert à tout Internet** par défaut (`ssh_source_cidrs`, voir `terraform/variables.tf`) : le déploiement automatique vient d'IP GitHub dynamiques. La protection est l'accès par clé seule ; **fail2ban** réduit le bruit : jail `sshd` (5 échecs, ban 1 h) et jail `recidive` (3 bans en 24 h, ban 1 semaine, sur tous les ports de l'hôte ; pas 80 ni 443, que Docker relaie).
- **Firewall Hetzner** : seuls 2222, 80 et 443.
- **Mises à jour** automatiques (`unattended-upgrades`) du système et de Docker (`/etc/apt/apt.conf.d/53docker.conf` ; une mise à jour de Docker redémarre les conteneurs, quelques secondes d'interruption), reboot à 4 h si nécessaire ; VPS rebooté en fin de provisioning. `cloud-init.yaml` décrit l'état désiré pour une recréation ; il n'est pas rejoué sur le serveur actuel, et le modifier ne recrée pas le VPS (`ignore_changes`, `terraform/main.tf`) : un changement s'applique aussi à la main sur le serveur en place.
- **Token Hetzner** `sensitive`, jamais commité. **IP primaire** détachée du serveur (`auto_delete = false`, `prevent_destroy = true`) : recréer le VPS ne change jamais l'IP.
- **Actions GitHub** épinglées par SHA, mises à jour par [Dependabot](../.github/dependabot.yml).
- **Docker socket** : Traefik et le portail n'y accèdent jamais directement, seulement via `docker-socket-proxy` (lecture seule). Voir `docker/traefik/README.md`.
- **Logs Docker** plafonnés (10 Mo x 3 par conteneur) : sans cela, `json-file` peut remplir le disque.

## Traefik (`docker/traefik/dynamic/middlewares.yml`)

- **CSP** sur `secure-headers`, pour tous les sites derrière Traefik. Aucun `'unsafe-eval'` ; `'unsafe-inline'` sur `style-src` : `<style>` du portail ; `data:` sur `img-src` : les drapeaux du bouton de langue d'arcadepipe, des images écrites dans son CSS ; `googletagmanager.com` et `google-analytics.com` : Google Analytics, injecté après consentement du visiteur (jamais de script inline). Après un changement de CSP, `npm run smoke` (dépôt arcadepipe, dossier `e2e/`) signale toute ressource bloquée. Si `www.google-analytics.com` est bloqué chez le visiteur, gtag bascule sur `www.google.com/g/collect`, non autorisé : erreurs console sans conséquence.
- **Rate-limit** (`rate-limit`) : 20 req/s par IP (burst 40) sur `arcadepipe-api` et le portail. **Pas sur `arcadepipe-web`** (fichiers statiques) : une page charge une quarantaine de fichiers JS, donc un second onglet ou une IP partagée dépasserait le burst et la musique recevrait des 429.
- **Taille des requêtes** (`api-body-limit`) : 10 Ko sur le corps envoyé au routeur `arcadepipe-api` uniquement. Jamais sur `arcadepipe-web` (musique de plusieurs Mo) ; seul `maxRequestBodyBytes` est posé, jamais `maxResponseBodyBytes`.

## Gramps Web (`docker/gramps/`)

- **Données personnelles** (personnes vivantes) : inscription fermée, télémétrie coupée, absent du portail, `X-Robots-Tag: noindex`.
- **Premier démarrage non exposé** (`GRAMPS_EXPOSE=false`) : l'assistant de Gramps Web laisserait le premier visiteur créer le compte propriétaire ; il est créé en ligne de commande avant d'ouvrir la route.
- **Middlewares dédiés** `gramps-headers` (sans la CSP d'arcadepipe, qui bloquerait les cartes), `gramps-rate-limit` (burst 200) et `gramps-login-limit` (5 essais/min par IP sur `/api/token/`). CSP propre à Gramps : à écrire, voir la roadmap de `docker/gramps/README.md`.
- **Valkey et le worker Celery** hors de `traefik-public` (réseau `gramps-internal` seulement).
