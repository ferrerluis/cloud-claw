locals {
  # one() returns null when the list is empty (module count = 0), never errors
  instance_public_ip = (
    var.cloud_provider == "aws"
    ? one(module.aws[*].instance_public_ip)
    : one(module.digitalocean[*].instance_public_ip)
  )
}

output "provider_used" {
  description = "Cloud provider that was deployed."
  value       = var.cloud_provider
}

output "instance_public_ip" {
  description = "Public IP address of the server."
  value       = local.instance_public_ip
}

output "ssh_command" {
  description = "SSH command to connect to the instance."
  value       = "ssh ${var.admin_username}@${local.instance_public_ip}"
}

output "tailscale_note" {
  description = "Tailscale access information."
  value = var.tailscale_enabled ? (
    "Tailscale is enabled. Once the instance boots (~2 min), the device '${var.project_name}' should appear in your Tailscale admin console. Dashboard: http://${var.project_name}:18789"
  ) : (
    "Tailscale is DISABLED. Use an SSH tunnel to reach the dashboard: ssh -L 18789:127.0.0.1:18789 ${var.admin_username}@${local.instance_public_ip}  then open http://localhost:18789"
  )
}

output "dashboard_url" {
  description = "OpenClaw dashboard URL (accessible after bootstrap completes, ~2-3 min after apply)."
  value = var.tailscale_enabled ? (
    "http://${var.project_name}:18789  (via Tailscale — connect your device to the same tailnet first)"
  ) : (
    "http://localhost:18789  (after running the SSH tunnel shown in tailscale_note)"
  )
}

output "bootstrap_log_command" {
  description = "Command to watch the bootstrap log on the server."
  value       = "ssh ${var.admin_username}@${local.instance_public_ip} 'tail -f /var/log/openclaw-bootstrap.log'"
}
