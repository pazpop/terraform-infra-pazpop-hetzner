variable "hcloud_token" {
  description = "Token API Hetzner Cloud (console.hetzner.cloud > Security > API Tokens, scope Read & Write)"
  type        = string
  sensitive   = true
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
    IP autorisées à se connecter en SSH (port 22). Par défaut ouvert à tout
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
