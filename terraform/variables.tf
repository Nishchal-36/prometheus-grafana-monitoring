variable "prefix" {
  description = "Prefix used for all resource names"
  type        = string
  default     = "monlab"
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "centralindia"
}

variable "vm_size" {
  description = "VM size for all three virtual machines"
  type        = string
  default     = "Standard_B2ms"
}

variable "admin_username" {
  description = "Admin username for the Linux and Windows VMs"
  type        = string
  default     = "azureuser"
}

variable "allowed_ip" {
  description = "Public IP (CIDR) allowed to reach RDP/SSH/Grafana/Prometheus. Leave empty to auto-detect your current public IP."
  type        = string
  default     = ""
}

variable "repo_raw_base" {
  description = "Raw base URL of this repository on GitHub (used by the Windows setup script to download files)"
  type        = string
  default     = "https://raw.githubusercontent.com/YOUR_GITHUB_USER/prometheus-grafana-monitoring/main"
}

variable "github_repo_url" {
  description = "HTTPS clone URL of this repository (used by cloud-init on the monitoring VM)"
  type        = string
  default     = "https://github.com/YOUR_GITHUB_USER/prometheus-grafana-monitoring.git"
}

variable "tags" {
  description = "Additional tags applied to all resources"
  type        = map(string)
  default     = {}
}
