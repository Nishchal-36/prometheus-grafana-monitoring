###############################################################################
# Prometheus + Grafana monitoring lab
#   * 2x Windows Server 2022 VMs running Nginx + a Node.js demo app + exporters
#     (the pair we compare / monitor)
#   * 1x Ubuntu VM running the Docker monitoring stack
#     (Prometheus, Alertmanager, Grafana, Loki, Alloy, node_exporter)
###############################################################################

data "http" "myip" {
  count = var.allowed_ip == "" ? 1 : 0
  url   = "https://ifconfig.me/ip"
}

locals {
  allowed_ip = var.allowed_ip != "" ? var.allowed_ip : "${trimspace(data.http.myip[0].response_body)}/32"

  base_tags = merge(
    {
      project     = "prometheus-grafana-monitoring"
      environment = "lab"
      managed_by  = "terraform"
    },
    var.tags
  )

  web_tags = merge(local.base_tags, { role = "web", monitoring = "true" })
  mon_tags = merge(local.base_tags, { role = "monitoring", monitoring = "true" })
}

resource "azurerm_resource_group" "rg" {
  name     = "rg-${var.prefix}-monitoring"
  location = var.location
  tags     = local.base_tags
}

###############################################################################
# Network
###############################################################################

resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-${var.prefix}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]
  tags                = local.base_tags
}

resource "azurerm_subnet" "web" {
  name                 = "snet-web"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_subnet" "monitoring" {
  name                 = "snet-monitoring"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.2.0/24"]
}

resource "azurerm_network_security_group" "web" {
  name                = "nsg-${var.prefix}-web"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = local.web_tags

  security_rule {
    name                       = "allow-rdp-from-admin"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3389"
    source_address_prefix      = local.allowed_ip
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-http-public"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-exporters-from-monitoring"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["3000", "9113", "9182"]
    source_address_prefix      = "10.0.2.0/24"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_security_group" "monitoring" {
  name                = "nsg-${var.prefix}-monitoring"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = local.mon_tags

  security_rule {
    name                       = "allow-ssh-from-admin"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = local.allowed_ip
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-grafana-from-admin"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3000"
    source_address_prefix      = local.allowed_ip
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-prometheus-from-admin"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "9090"
    source_address_prefix      = local.allowed_ip
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-alertmanager-from-admin"
    priority                   = 130
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "9093"
    source_address_prefix      = local.allowed_ip
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-loki-from-web-subnet"
    priority                   = 140
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3100"
    source_address_prefix      = "10.0.1.0/24"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "web" {
  subnet_id                 = azurerm_subnet.web.id
  network_security_group_id = azurerm_network_security_group.web.id
}

resource "azurerm_subnet_network_security_group_association" "monitoring" {
  subnet_id                 = azurerm_subnet.monitoring.id
  network_security_group_id = azurerm_network_security_group.monitoring.id
}

###############################################################################
# Public IPs
###############################################################################

resource "azurerm_public_ip" "web" {
  count               = 2
  name                = "pip-${var.prefix}-web-${count.index + 1}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.web_tags
}

resource "azurerm_public_ip" "monitoring" {
  name                = "pip-${var.prefix}-monitoring"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.mon_tags
}

###############################################################################
# Windows VMs (the comparison pair)
###############################################################################

resource "random_password" "windows_admin" {
  length           = 24
  special          = true
  override_special = "!@#%^*_-"
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
}

resource "azurerm_network_interface" "web" {
  count               = 2
  name                = "nic-${var.prefix}-web-${count.index + 1}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = local.web_tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.web.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.web[count.index].id
  }
}

resource "azurerm_windows_virtual_machine" "web" {
  count               = 2
  name                = "win-web-${count.index + 1}"
  computer_name       = "win-web-${count.index + 1}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  size                = var.vm_size
  admin_username      = var.admin_username
  admin_password      = random_password.windows_admin.result
  tags                = local.web_tags

  network_interface_ids = [
    azurerm_network_interface.web[count.index].id,
  ]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-datacenter-g2"
    version   = "latest"
  }

  identity {
    type = "SystemAssigned"
  }

  provision_vm_agent = true
}

resource "azurerm_virtual_machine_extension" "web_setup" {
  count                      = 2
  name                       = "setup-app-stack"
  virtual_machine_id         = azurerm_windows_virtual_machine.web[count.index].id
  publisher                  = "Microsoft.Compute"
  type                       = "CustomScriptExtension"
  type_handler_version       = "1.10"
  auto_upgrade_minor_version = true
  tags                       = local.web_tags

  settings = jsonencode({
    fileUris = ["${var.repo_raw_base}/scripts/windows-setup.ps1"]
  })

  protected_settings = jsonencode({
    commandToExecute = "powershell.exe -ExecutionPolicy Bypass -File windows-setup.ps1 -RepoRawBase \"${var.repo_raw_base}\" -LokiUrl \"http://${azurerm_linux_virtual_machine.monitoring.private_ip_address}:3100\" -ServerName \"${azurerm_windows_virtual_machine.web[count.index].name}\""
  })
}

###############################################################################
# Linux monitoring VM
###############################################################################

resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "random_password" "grafana_admin" {
  length           = 24
  special          = true
  override_special = "!@#%^*_-"
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
}

resource "azurerm_network_interface" "monitoring" {
  name                = "nic-${var.prefix}-monitoring"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = local.mon_tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.monitoring.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.monitoring.id
  }
}

resource "azurerm_linux_virtual_machine" "monitoring" {
  name                = "mon-linux-1"
  computer_name       = "mon-linux-1"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  size                = var.vm_size
  admin_username      = var.admin_username
  tags                = local.mon_tags

  network_interface_ids = [
    azurerm_network_interface.monitoring.id,
  ]

  admin_ssh_key {
    username   = var.admin_username
    public_key = tls_private_key.ssh.public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  identity {
    type = "SystemAssigned"
  }

  provision_vm_agent = true

  custom_data = base64encode(templatefile("${path.module}/cloud-init.yaml.tftpl", {
    repo_url             = var.github_repo_url
    grafana_password     = random_password.grafana_admin.result
    windows_targets_json = jsonencode([{ targets = [for ip in azurerm_network_interface.web[*].private_ip_address : "${ip}:9182"], labels = { role = "web", os = "windows" } }])
    nginx_targets_json   = jsonencode([{ targets = [for ip in azurerm_network_interface.web[*].private_ip_address : "${ip}:9113"], labels = { role = "web", app = "nginx" } }])
    app_targets_json     = jsonencode([{ targets = [for ip in azurerm_network_interface.web[*].private_ip_address : "${ip}:3000"], labels = { role = "web", app = "node-demo" } }])
  }))
}

###############################################################################
# Local credential bundle (gitignored)
###############################################################################

resource "local_file" "monitoring_ssh_key" {
  filename = "${path.module}/monitoring_ssh_key.pem"
  content  = tls_private_key.ssh.private_key_pem
}

resource "local_file" "credentials" {
  filename = "${path.module}/.generated-credentials.txt"
  content  = <<-EOT
    # Generated by Terraform - DO NOT COMMIT (gitignored)

    [Windows VMs]
    admin user:     ${var.admin_username}
    admin password: ${random_password.windows_admin.result}
    win-web-1 RDP:  mstsc /v:${azurerm_public_ip.web[0].ip_address}
    win-web-2 RDP:  mstsc /v:${azurerm_public_ip.web[1].ip_address}

    [Monitoring VM]
    ssh:            ssh -i monitoring_ssh_key.pem ${var.admin_username}@${azurerm_public_ip.monitoring.ip_address}
    Grafana:        http://${azurerm_public_ip.monitoring.ip_address}:3000  (admin / ${random_password.grafana_admin.result})
    Prometheus:     http://${azurerm_public_ip.monitoring.ip_address}:9090
    Alertmanager:   http://${azurerm_public_ip.monitoring.ip_address}:9093
  EOT
}
