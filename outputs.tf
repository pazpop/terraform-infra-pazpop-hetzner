output "server_ip" {
  value = hcloud_primary_ip.arcadepipe_ipv4.ip_address
}

output "ssh_command" {
  value = "ssh -i ~/.ssh/arcadepipe_vps -p 2222 root@${hcloud_primary_ip.arcadepipe_ipv4.ip_address}"
}
