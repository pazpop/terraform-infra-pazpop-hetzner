variable "hcloud_token" {
  description = <<-EOT
    Token API Hetzner Cloud (console.hetzner.cloud > Security > API Tokens,
    scope Read & Write). Optionnel ici : si non renseigné (default = null),
    le provider hcloud (provider.tf) retombe automatiquement sur la variable
    d'environnement HCLOUD_TOKEN, lue nativement par le provider lui-même —
    aucun changement necessaire dans provider.tf pour ça, un `null` explicite
    suffit à déclencher ce comportement.

    NE JAMAIS renseigner les deux à la fois (terraform.tfvars ET HCLOUD_TOKEN) :
    terraform.tfvars prime SILENCIEUSEMENT sur la variable d'environnement dès
    qu'il contient une valeur non vide. En cas de rotation du token faite
    seulement via HCLOUD_TOKEN, un ancien token oublié dans terraform.tfvars
    resterait utilisé sans le moindre avertissement — jusqu'au jour où lui
    seul expire ou est révoqué, provoquant des 401 déroutants puisque "le
    token vient d'être changé". Choisir un seul mécanisme et s'y tenir.
  EOT
  type        = string
  sensitive   = true
  default     = null
}

variable "ssh_public_key_path" {
  description = "Chemin vers la clé publique SSH dédiée à installer sur le VPS"
  type        = string
  default     = "~/.ssh/arcadepipe_vps.pub"
}

variable "server_name" {
  type    = string
  default = "arcadepipe-vps"
}

variable "server_type" {
  description = "cx23 = 2 vCPU / 4GB, largement suffisant pour ce projet (moins cher que cx22)"
  type        = string
  default     = "cx23"
}

variable "location" {
  description = "Datacenter Hetzner (nbg1 = Nuremberg, fsn1 = Falkenstein, hel1 = Helsinki)"
  type        = string
  default     = "nbg1"
}

variable "ssh_source_cidrs" {
  description = <<-EOT
    IP autorisées à se connecter en SSH (port 2222, voir cloud-init.yaml —
    sshd n'écoute plus sur le 22 par défaut). Par défaut ouvert à tout
    Internet (0.0.0.0/0, ::/0) — pratique pour démarrer, mais surexposé.
    Pour restreindre à ta seule IP : trouve-la avec `curl -4 icanhazip.com`,
    puis dans terraform.tfvars :
      ssh_source_cidrs = ["TON_IP/32"]
    (chaque changement d'IP, par ex. en changeant de réseau, nécessite de
    mettre à jour cette valeur et relancer `tofu apply`)
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0", "::/0"]
}
