# Backup de la DB arcadepipe

Backup quotidien automatisé (3h du matin) de la base SQLite du jeu (volume Docker `backend_data`), via un timer systemd sur la VPS.

## Déploiement

```bash
cd backup
./deploy-backup.sh
```

Idempotent — relançable sans risque après toute modification de `backup-arcadepipe-db.sh`, `restore-arcadepipe-db.sh` ou des unités systemd.

## Mécanisme

Un conteneur jetable (`backup/Dockerfile` — alpine + `sqlite3`, ~10 Mo, construit localement sur la VPS, jamais publié) monte le volume `backend_data` et exécute `sqlite3 arcadepipe.db ".backup '...'"` — l'API de backup officielle de SQLite, conçue pour copier une base **vivante** (mode WAL) de façon cohérente. Jamais de `cp` direct du fichier `.db` : un `cp` pourrait capturer un état à cheval entre le fichier principal et son `-wal`, potentiellement corrompu.

Le montage n'est **pas** en lecture seule, contrairement à l'intention de départ — testé en réel : un montage `:ro` fait échouer `sqlite3` avec `unable to open database file`, même pour une simple lecture. Ouvrir une base en mode WAL exige de pouvoir créer/maintenir son fichier `-shm` (mémoire partagée de coordination des lecteurs), ce qu'un montage `:ro` interdit.

Chaque backup produit est vérifié immédiatement après sa création (`PRAGMA integrity_check`, fichier non vide) — pas seulement au moment d'une restauration. Un `.backup` sur une source déjà corrompue produirait sinon un backup tout aussi corrompu, silencieusement.

## Emplacement et rétention

```
/var/backups/arcadepipe/
├── daily/    # 7 plus récents conservés
└── weekly/   # 4 plus récents conservés (copie du backup du dimanche)
```

Nommage : `arcadepipe_YYYY-MM-DD_HHMM.db`.

## Destination — comment migrer vers un stockage distant plus tard

Une seule variable dans `backup-arcadepipe-db.sh` isole la destination locale :

```bash
BACKUP_DEST="/var/backups/arcadepipe"
```

Passer à un stockage distant (rclone, S3, etc.) plus tard **s'ajoute** à ce qui existe, ça ne le remplace pas : le disque local reste un tampon même une fois le remote branché. La rétention locale (7 quotidiens/4 hebdomadaires) continue de tourner telle quelle ; il suffit d'ajouter, en toute fin de `backup-arcadepipe-db.sh`, une étape du style :

```bash
rclone sync "$BACKUP_DEST" remote:mon-bucket/arcadepipe
```

Aucune réécriture du mécanisme de backup lui-même — pas implémenté ici (pas de stockage distant pour l'instant).

## Restauration

### Procédure automatisée (recommandée)

```bash
ssh arcadepipe-vps
~/backup/restore-arcadepipe-db.sh /var/backups/arcadepipe/daily/arcadepipe_2026-09-17_0300.db
```

Le script fait, dans l'ordre :

1. **Vérifie l'intégrité du backup candidat** (`PRAGMA integrity_check`) — avant de toucher à quoi que ce soit de vivant. Si le fichier choisi est corrompu, on s'arrête ici, rien n'a encore été modifié.
2. **Arrête le conteneur backend** (`docker compose stop backend`) — le frontend/Traefik restent en marche, seules les routes `/api/*` échouent pendant la restauration.
3. **Supprime les fichiers `-wal`/`-shm` de l'ANCIENNE base.** C'est le piège classique d'une restauration SQLite en mode WAL : copier le nouveau `.db` par-dessus l'ancien sans supprimer son `-wal`/`-shm` ferait rejouer, au prochain démarrage, un journal WAL qui appartient à l'ancienne base sur la nouvelle — corruption silencieuse quasi garantie, découverte bien plus tard. Le fichier produit par `.backup` est autonome (pas de WAL actif) ; SQLite en recrée un propre tout seul au premier accès.
4. **Copie le backup validé** à la place de l'ancienne base dans le volume.
5. **Redémarre le backend** et vérifie que `/api/health` répond.

### Procédure manuelle (si le script n'est pas disponible)

```bash
# 1. Intégrité du candidat
docker run --rm -v /var/backups/arcadepipe/daily:/backup:ro arcadepipe-backup-tool \
  sqlite3 /backup/arcadepipe_2026-09-17_0300.db "PRAGMA integrity_check;"

# 2. Arrêt du backend
cd ~/arcadepipe && docker compose stop backend

# 3. Purge des -wal/-shm de l'ancienne base (ÉTAPE CRITIQUE, voir ci-dessus)
docker run --rm -v backend_data:/data arcadepipe-backup-tool \
  sh -c "rm -f /data/arcadepipe.db-wal /data/arcadepipe.db-shm"

# 4. Copie du backup
docker run --rm -v /var/backups/arcadepipe/daily:/backup:ro -v backend_data:/data arcadepipe-backup-tool \
  sh -c "cp /backup/arcadepipe_2026-09-17_0300.db /data/arcadepipe.db"

# 5. Redémarrage + vérification
cd ~/arcadepipe && docker compose start backend
curl -sS https://arcadepipe.pazpop.net/api/health
```

## Valider le mécanisme (test de bout en bout)

```bash
./test-backup-restore.sh
```

Contre la vraie API en prod (pas de simulation) : insère un score de test unique (nom horodaté) → backup → suppression en direct → restauration → vérifie le retour → nettoie (garanti même en cas d'échec en cours de route, via un `trap` sur la sortie du script). Le fichier de backup produit pendant le test n'est pas supprimé — c'est un backup légitime, la rétention normale (7 jours) s'en charge.

## Test réel exécuté

Un test complet a été exécuté sur la VPS de production lors de la mise en place de ce mécanisme, à deux reprises (la deuxième fois pour valider le correctif du bug de permissions ci-dessous) : insertion d'un score de test → backup → suppression du score en live → restauration → vérification du retour **et** vérification qu'un nouveau score peut être écrit après restauration → nettoyage. Pas simulé : sur la vraie base, avec un vrai arrêt/redémarrage du conteneur backend.

Trois bugs réels trouvés et corrigés pendant ce test (aucun n'était visible en relisant le code, seulement en l'exécutant) :

1. **`deploy-backup.sh` ne déployait rien du tout, silencieusement.** `ssh -n` redirige stdin depuis `/dev/null` — incompatible avec le heredoc utilisé pour envoyer le script distant via `bash -s`. Le script distant s'exécutait sur une entrée vide, sans la moindre erreur, et l'exécution locale affichait quand même "déploiement terminé".
2. **`sqlite3` échoue systématiquement avec un montage `:ro`**, y compris pour une simple lecture (`PRAGMA integrity_check`) sur un fichier qui n'est même plus en mode WAL. SQLite a besoin de pouvoir créer des fichiers de verrouillage dans le répertoire contenant la base, quelle que soit l'opération. Tous les montages utilisés avec `sqlite3` dans les deux scripts sont donc en lecture-écriture (celui utilisé pour un simple `cp`, lui, reste `:ro`).
3. **Le fichier restauré appartenait à `root`** (le conteneur jetable tourne en root), pas à l'utilisateur du backend (`appuser`, uid 1000) — le backend redémarrait avec une base illisible en écriture (`attempt to write a readonly database`). `restore-arcadepipe-db.sh` fait maintenant un `chown 1000:1000` après la copie.

## Limites connues

- Backup local uniquement pour l'instant (voir *Destination* ci-dessus) — une panne disque de la VPS emporte à la fois la base live et ses backups. Acceptable en l'état pour un POC ; à revoir avant tout usage avec des données qu'on ne peut pas se permettre de perdre.
- Aucune alerte en cas d'échec du timer — voir Roadmap du README principal (déjà identifié comme point ouvert plus large, pas spécifique au backup).
