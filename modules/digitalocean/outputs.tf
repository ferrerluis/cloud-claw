output "instance_public_ip" {
  description = "Public IP address of the Droplet."
  value       = digitalocean_droplet.this.ipv4_address
}

output "droplet_id" {
  description = "Droplet ID."
  value       = digitalocean_droplet.this.id
}

output "volume_name" {
  description = "Block storage volume name."
  value       = local.do_volume_name
}

output "ssh_command" {
  description = "SSH command to connect to the Droplet."
  value       = "ssh root@${digitalocean_droplet.this.ipv4_address}"
}
