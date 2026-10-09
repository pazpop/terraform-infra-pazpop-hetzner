# Backups

Deux backups quotidiens sur la VPS, par timers systemd, avec la même image jetable et la même rétention (`common.sh`) :

- **arcadepipe** (3h) : la base SQLite du jeu (volume `backend_data`), décrit ci-dessous ;
- **Gramps Web** (3h30) : `backup-gramps.sh`, décrit dans [docker/gramps/README.md](../docker/gramps/README.md#backup-et-restauration).

## Déploiement

```bash
cd backup
./deploy-backup.sh
```

Déploie les deux backups. Idempotent : relançable sans risque après toute modification d'un script ou d'une unité systemd.

## Mécanisme (arcadepipe)

Un conteneur jetable (`Dockerfile`, image `backup-tool` : alpine + `sqlite3`, ~10 Mo, construite sur la VPS, jamais publiée) monte le volume `backend_data` et exécute `sqlite3 arcadepipe.db ".backup '...'"` : l'API de backup officielle de SQLite, conçue pour copier une base **vivante** (mode WAL) de façon cohérente. Jamais de `cp` du fichier `.db` : il pourrait capturer un état à cheval entre le fichier principal et son `-wal`.

Le montage n'est **pas** en lecture seule : avec `:ro`, `sqlite3` échoue (`unable to open database file`) même pour une simple lecture, car il doit pouvoir créer ses fichiers de verrou à côté de la base.

Chaque backup est vérifié dès sa création (`PRAGMA integrity_check`, fichier non vide) : un `.backup` d'une source corrompue produirait sinon un backup tout aussi corrompu, silencieusement.

## Emplacement et rétention

```
/var/backups/arcadepipe/
├── daily/    # 7 plus récents conservés
└── weekly/   # 4 plus récents conservés (copie du backup du dimanche)
```

Nommage : `arcadepipe_YYYY-MM-DD_HHMM.db`.

## Stockage distant (non implémenté)

`BACKUP_DEST` isole la destination locale dans chaque script. Un stockage distant **s'ajoutera** au disque local, qui reste un tampon : une étape en fin de script suffit, par exemple :

```bash
rclone sync "$BACKUP_DEST" remote:mon-bucket/arcadepipe
```

## Restauration

### Procédure automatisée (recommandée)

```bash
ssh arcadepipe-vps
~/backup/restore-arcadepipe-db.sh /var/backups/arcadepipe/daily/arcadepipe_2026-09-17_0300.db
```

Le script fait, dans l'ordre :

1. **Vérifie l'intégrité du backup candidat** (`PRAGMA integrity_check`) avant de toucher à quoi que ce soit : s'il est corrompu, rien n'est modifié.
2. **Arrête le conteneur backend** (`docker compose stop backend`) : le site reste en ligne, seules les routes `/api/*` échouent pendant la restauration. Il est relancé à la sortie du script, même si une étape échoue. **La base en place est d'abord copiée** dans `/var/backups/arcadepipe/avant-restauration/` : si le mauvais fichier a été restauré, relancer le script sur cette copie annule l'opération.
3. **Supprime les fichiers `-wal`/`-shm` de l'ANCIENNE base.** Sinon SQLite rejouerait, au prochain démarrage, le journal de l'ancienne base sur la nouvelle : corruption silencieuse. Le fichier produit par `.backup` est autonome ; SQLite recrée un `-wal` propre au premier accès.
4. **Copie le backup validé** à la place de l'ancienne base, et le rend au propriétaire du backend (`chown 1000:1000`, l'utilisateur `appuser` ; le conteneur jetable écrit en root).
5. **Redémarre le backend** et vérifie que `/api/health` répond.

### Procédure manuelle (si le script n'est pas disponible)

```bash
# 1. Intégrité du candidat
docker run --rm -v /var/backups/arcadepipe/daily:/backup backup-tool \
  sqlite3 /backup/arcadepipe_2026-09-17_0300.db "PRAGMA integrity_check;"

# 2. Arrêt du backend
cd ~/arcadepipe && docker compose stop backend

# 3. Purge des -wal/-shm de l'ancienne base (ÉTAPE CRITIQUE, voir ci-dessus)
docker run --rm -v backend_data:/data backup-tool \
  rm -f /data/arcadepipe.db-wal /data/arcadepipe.db-shm

# 4. Copie du backup
docker run --rm -v /var/backups/arcadepipe/daily:/backup:ro -v backend_data:/data backup-tool \
  sh -c "cp /backup/arcadepipe_2026-09-17_0300.db /data/arcadepipe.db && chown 1000:1000 /data/arcadepipe.db"

# 5. Redémarrage + vérification
cd ~/arcadepipe && docker compose start backend
curl -sS https://arcadepipe.pazpop.net/api/health
```

## Valider le mécanisme (test de bout en bout)

```bash
./test-backup-restore.sh
```

Contre la vraie API en prod : insère un score de test unique (nom horodaté) → backup → suppression en direct → restauration → vérifie le retour → nettoie (garanti même en cas d'échec, via un `trap` sur la sortie du script). À lancer à une heure creuse : un vrai score envoyé entre le backup et la restauration, quelques secondes, serait perdu. Le backup produit compte dans la rétention (7 quotidiens) : il chasse le plus ancien.

## Limites connues

- Backups locaux uniquement : une panne disque de la VPS emporte la base et ses backups (voir *Stockage distant*).
- Aucune alerte en cas d'échec d'un timer : voir la Roadmap du README principal.
