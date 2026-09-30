variable "hcloud_token" {
  description = "Token API Hetzner (Read & Write). null = HCLOUD_TOKEN ; jamais les deux (voir README)."
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
  description = "IP autorisées en SSH (port 2222). Ouvert par défaut : le CI déploie depuis des IP GitHub dynamiques (voir docs/securite.md)."
  type        = list(string)
  default     = ["0.0.0.0/0", "::/0"]
}
