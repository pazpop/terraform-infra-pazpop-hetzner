# Sécurité

## Accès au VPS

- **SSH** sur le port **2222** (moins de bruit de scans), root interdit (`PermitRootLogin no`), mot de passe désactivé : seule la clé, sur le compte `deploy` (sudo NOPASSWD, groupe `docker`).
- **Ouvert à tout Internet** par défaut (`ssh_source_cidrs`, voir `terraform/variables.tf`) : le déploiement automatique vient d'IP GitHub dynamiques. La vraie protection est **fail2ban** : jail `sshd` (5 échecs, ban 1 h) et jail `recidive` (3 bans en 24 h, ban 1 semaine, tous ports).
- **Firewall Hetzner** : seuls 2222, 80 et 443.
- **Mises à jour** automatiques (`unattended-upgrades`), reboot à 4 h si nécessaire ; VPS rebooté en fin de provisioning. `cloud-init.yaml` décrit l'état désiré pour une recréation ; il n'est pas rejoué sur le serveur actuel.
- **Token Hetzner** `sensitive`, jamais commité. **IP primaire** détachée du serveur (`auto_delete = false`, `prevent_destroy = true`) : recréer le VPS ne change jamais l'IP.
- **Actions GitHub** épinglées par SHA, mises à jour par [Dependabot](../.github/dependabot.yml).
- **Docker socket** : Traefik et le portail n'y accèdent jamais directement, seulement via `docker-socket-proxy` (lecture seule). Voir `docker/traefik/README.md`.
- **Logs Docker** plafonnés (10 Mo x 3 par conteneur) : sans cela, `json-file` peut remplir le disque.

## Traefik (`docker/traefik/dynamic/middlewares.yml`)

- **CSP** sur `secure-headers`, pour tous les sites derrière Traefik. `'unsafe-eval'` : lecteur de musique d'arcadepipe (libopenmpt en WebAssembly, `lib/libopenmpt.worklet.js`) ; `'unsafe-inline'` sur `style-src` : `<style>` du portail ; `googletagmanager.com` et `google-analytics.com` : Google Analytics, injecté après consentement du visiteur (jamais de script inline). Testé en réel le 2026-09-18 : zéro violation. Si `www.google-analytics.com` est bloqué chez le visiteur, gtag bascule sur `www.google.com/g/collect`, non autorisé : erreurs console sans conséquence.
- **Rate-limit** (`rate-limit`) : 20 req/s par IP (burst 40) sur `arcadepipe-api` et le portail. **Pas sur `arcadepipe-web`** (fichiers statiques) : une quarantaine de fichiers JS par page, un second onglet ou une IP partagée dépassait le burst et provoquait des 429 sur la musique.
- **Taille des requêtes** (`api-body-limit`) : 10 Ko sur le corps envoyé au routeur `arcadepipe-api` uniquement. Jamais sur `arcadepipe-web` (musique de plusieurs centaines de Ko) ; seul `maxRequestBodyBytes` est posé, jamais `maxResponseBodyBytes`.
