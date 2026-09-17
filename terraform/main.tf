resource "hcloud_ssh_key" "arcadepipe" {
  name       = "arcadepipe-vps"
  public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))
}

resource "hcloud_firewall" "arcadepipe" {
  name = "arcadepipe-firewall"

  // sshd n'écoute plus que sur ce port (voir ssh.socket.d/override.conf sur
  // la VPS) : le 22 par défaut attire énormément de scans automatisés.
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "2222"
    source_ips = var.ssh_source_cidrs
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "80"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "443"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
}

// IP séparée du cycle de vie du serveur : détruire/recréer le serveur ne la
// touche pas (auto_delete = false), donc le VPS garde toujours la même IP
// et le enregistrement DNS A n'a jamais besoin d'être changé.
resource "hcloud_primary_ip" "arcadepipe_ipv4" {
  name        = "arcadepipe-vps-ip"
  type        = "ipv4"
  location    = var.location
  auto_delete = false

  // Garde-fou supplémentaire (pas une protection absolue) : bloque un
  // "tofu destroy"/apply qui supprimerait cette ressource PAR ERREUR DE
  // CONFIGURATION (ex: un refactor qui la retire du .tf par mégarde) — ça
  // ne protège pas contre un "tofu destroy" volontaire (ou lancé dans le
  // mauvais workspace) auquel on répond "yes". La vraie protection reste
  // de toujours lire un "tofu plan" avant d'appliquer. Seule ressource du
  // stack avec une conséquence DNS si elle disparaît (voir commentaire
  // ci-dessus : le A record ne suit jamais le VPS, il suit cette IP).
  lifecycle {
    prevent_destroy = true
  }
}

// Volontairement PAS de prevent_destroy ici, contrairement à
// hcloud_primary_ip ci-dessus — c'est l'inverse qu'on veut sur ce serveur :
// pouvoir le détruire/recréer sans friction (disaster-recovery, changement
// de cloud-init.yaml qui ne s'applique qu'à la création). Testé en
// conditions réelles cette session : un destroy/recreate complet du VPS,
// suivi d'une reconfiguration automatique intégrale via cloud-init (SSH
// durci, fail2ban, compte deploy) sans aucune intervention manuelle.
// Mettre prevent_destroy dessus casserait ce mécanisme déjà validé, pour un
// bénéfice nul : contrairement à l'IP, recréer le serveur ne casse aucun
// enregistrement DNS externe.
resource "hcloud_server" "arcadepipe" {
  name         = var.server_name
  server_type  = var.server_type
  image        = "ubuntu-24.04"
  location     = var.location
  ssh_keys     = [hcloud_ssh_key.arcadepipe.id]
  firewall_ids = [hcloud_firewall.arcadepipe.id]

  public_net {
    ipv4 = hcloud_primary_ip.arcadepipe_ipv4.id
  }

  user_data = templatefile("${path.module}/cloud-init.yaml", {
    ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))
  })

  // La clé Hetzner n'est injectée qu'au moment de la création du serveur ; la
  // faire tourner (ex: recréée après une suppression accidentelle dans la
  // console) ne doit jamais déclencher un remplacement du VPS existant.
  lifecycle {
    ignore_changes = [ssh_keys]
  }
}
