output "resource_group" {
  description = "Resource group name"
  value       = azurerm_resource_group.rg.name
}

output "windows_public_ips" {
  description = "Public IPs of the two Windows web VMs"
  value       = azurerm_public_ip.web[*].ip_address
}

output "windows_private_ips" {
  description = "Private IPs of the two Windows web VMs"
  value       = azurerm_network_interface.web[*].private_ip_address
}

output "monitoring_public_ip" {
  description = "Public IP of the Linux monitoring VM"
  value       = azurerm_public_ip.monitoring.ip_address
}

output "monitoring_private_ip" {
  description = "Private IP of the Linux monitoring VM"
  value       = azurerm_network_interface.monitoring.private_ip_address
}

output "grafana_url" {
  description = "Grafana URL"
  value       = "http://${azurerm_public_ip.monitoring.ip_address}:3000"
}

output "prometheus_url" {
  description = "Prometheus URL"
  value       = "http://${azurerm_public_ip.monitoring.ip_address}:9090"
}

output "alertmanager_url" {
  description = "Alertmanager URL"
  value       = "http://${azurerm_public_ip.monitoring.ip_address}:9093"
}

output "ssh_command" {
  description = "SSH command for the monitoring VM"
  value       = "ssh -i monitoring_ssh_key.pem ${var.admin_username}@${azurerm_public_ip.monitoring.ip_address}"
}

output "admin_username" {
  description = "Admin username for all VMs"
  value       = var.admin_username
}

output "windows_admin_password" {
  description = "Windows admin password"
  value       = random_password.windows_admin.result
  sensitive   = true
}

output "grafana_admin_password" {
  description = "Grafana admin password"
  value       = random_password.grafana_admin.result
  sensitive   = true
}
