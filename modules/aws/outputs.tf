output "instance_public_ip" {
  description = "Public IP address of the EC2 instance."
  value       = aws_instance.this.public_ip
}

output "instance_id" {
  description = "EC2 instance ID."
  value       = aws_instance.this.id
}

output "ebs_volume_id" {
  description = "EBS data volume ID."
  value       = local.ebs_volume_id
}

output "ssh_command" {
  description = "SSH command to connect to the instance."
  value       = "ssh ${var.admin_username}@${aws_instance.this.public_ip}"
}
