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
    "Tailscale is enabled. Once the instance boots (~2 min), the sidecar device '${var.project_name}' should appear in your Tailscale admin console. Dashboard is published with Tailscale Serve: https://${var.project_name} (or use dashboard_url_with_token_import for first-time auto-auth)."
    ) : (
    "Tailscale is DISABLED. Use an SSH tunnel to reach the dashboard: ssh -L 18789:127.0.0.1:18789 ${var.admin_username}@${local.instance_public_ip}  then open http://localhost:18789"
  )
}

output "dashboard_url" {
  description = "OpenClaw dashboard URL (accessible after bootstrap completes, ~2-3 min after apply)."
  value = var.tailscale_enabled ? (
    "https://${var.project_name}  (via Tailscale Serve sidecar — connect your device to the same tailnet first)"
    ) : (
    "http://localhost:18789  (after running the SSH tunnel shown in tailscale_note)"
  )
}

output "dashboard_url_with_token_import" {
  description = "First-time login URL that auto-imports the gateway token into Control UI via #token fragment."
  value = var.tailscale_enabled ? (
    nonsensitive("https://${var.project_name}/#token=${local.resolved_gateway_token}")
    ) : (
    nonsensitive("http://localhost:18789/#token=${local.resolved_gateway_token}  (after running the SSH tunnel shown in tailscale_note)")
  )
}

output "gateway_token" {
  description = "Gateway token used by OpenClaw Control UI and WebSocket auth."
  value       = nonsensitive(local.resolved_gateway_token)
}

output "pair_latest_command" {
  description = "Run after opening dashboard_url_with_token_import to approve the latest pending paired-device request."
  value       = "ssh ${var.admin_username}@${local.instance_public_ip} 'docker exec openclaw-openclaw-1 openclaw devices approve --latest --token ${nonsensitive(local.resolved_gateway_token)} --url ws://127.0.0.1:18789'"
}

output "whatsapp_login_command" {
  description = "Interactive command to link WhatsApp by scanning QR from your terminal."
  value       = "ssh -t ${var.admin_username}@${local.instance_public_ip} 'sudo docker exec -it openclaw-openclaw-1 openclaw channels login --channel whatsapp --verbose'"
}

output "bootstrap_log_command" {
  description = "Command to watch the bootstrap log on the server."
  value       = "ssh ${var.admin_username}@${local.instance_public_ip} 'tail -f /var/log/openclaw-bootstrap.log'"
}
