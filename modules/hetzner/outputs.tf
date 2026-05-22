output "instance_public_ip" {
  description = "Public IPv4 address of the Hetzner Cloud server."
  value       = hcloud_server.this.ipv4_address
}

output "server_id" {
  description = "Hetzner Cloud server ID."
  value       = hcloud_server.this.id
}

output "volume_id" {
  description = "Hetzner Cloud data volume ID."
  value       = local.hcloud_volume_id
}

output "ssh_command" {
  description = "SSH command to connect to the server."
  value       = "ssh ${var.admin_username}@${hcloud_server.this.ipv4_address}"
}
