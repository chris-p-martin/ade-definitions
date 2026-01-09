terraform {
  required_version = ">= 1.3.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

variable "environment_name" {
  description = "Name of the environment"
  type        = string
}

variable "location" {
  description = "Azure region for resources"
  type        = string
  default     = "eastus"
}

variable "vm_size" {
  description = "Size of the virtual machine"
  type        = string
  default     = "Standard_B2s"
}

variable "admin_username" {
  description = "Username for the VM administrator"
  type        = string
  default     = "azureuser"
  sensitive   = true
}

variable "enable_security_baseline" {
  type        = bool
  description = "Enable Azure security baselines and compliance on VM"
  default     = true
}

variable "enable_update_manager" {
  type        = bool
  description = "Enable Azure Update Manager v2 for patch management"
  default     = true
}

variable "patch_assessment_frequency" {
  type        = string
  description = "Frequency of patch assessments for Update Manager"
  default     = "Weekly"
  validation {
    condition     = contains(["Daily", "Weekly", "Monthly"], var.patch_assessment_frequency)
    error_message = "patch_assessment_frequency must be Daily, Weekly, or Monthly"
  }
}

variable "enable_guest_config" {
  type        = bool
  description = "Enable Azure Guest Configuration for compliance monitoring"
  default     = true
}

locals {
  resource_group_name = "rg-${var.environment_name}-vm"
  common_tags = {
    Environment = var.environment_name
    Type        = "VM"
    ManagedBy   = "ADE"
    CreatedAt   = timestamp()
  }
}

resource "azurerm_resource_group" "main" {
  name     = local.resource_group_name
  location = var.location
  tags     = local.common_tags
}

resource "azurerm_virtual_network" "main" {
  name                = "vnet-${var.environment_name}"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags
}

resource "azurerm_subnet" "internal" {
  name                 = "subnet-internal"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.2.0/24"]
}

resource "azurerm_network_security_group" "main" {
  name                = "nsg-${var.environment_name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags

  security_rule {
    name                       = "AllowSSH"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowHTTP"
    priority                   = 101
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowHTTPS"
    priority                   = 102
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "main" {
  subnet_id                 = azurerm_subnet.internal.id
  network_security_group_id = azurerm_network_security_group.main.id
}

resource "azurerm_public_ip" "main" {
  name                = "pip-${var.environment_name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  tags                = local.common_tags
}

resource "azurerm_network_interface" "main" {
  name                = "nic-${var.environment_name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags

  ip_configuration {
    name                          = "testconfiguration1"
    subnet_id                     = azurerm_subnet.internal.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.main.id
  }
}

resource "azurerm_linux_virtual_machine" "main" {
  name                = "vm-${var.environment_name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags

  size = var.vm_size

  admin_username = var.admin_username

  admin_ssh_key {
    username   = var.admin_username
    public_key = file("~/.ssh/id_rsa.pub")
  }

  network_interface_ids = [
    azurerm_network_interface.main.id,
  ]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-focal"
    sku       = "20_04-lts-gen2"
    version   = "latest"
  }
}

# Log Analytics Workspace for compliance monitoring and diagnostics
resource "azurerm_log_analytics_workspace" "law" {
  count               = var.enable_security_baseline ? 1 : 0
  name                = "law-${var.environment_name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = 30

  tags = local.common_tags
}

# Dependency Agent Extension for Update Manager v2 (Linux)
resource "azurerm_virtual_machine_extension" "dependency_agent" {
  count                      = var.enable_update_manager ? 1 : 0
  name                       = "DependencyAgentLinux"
  virtual_machine_id         = azurerm_linux_virtual_machine.main.id
  publisher                  = "Microsoft.Azure.Monitoring.DependencyAgent"
  type                       = "DependencyAgentLinux"
  type_handler_version       = "9.10"
  auto_upgrade_minor_version = true

  settings = jsonencode({
    enableAMA = true
  })

  tags = local.common_tags
}

# Azure Monitor Agent Extension for Update Manager v2 and security baseline (Linux)
resource "azurerm_virtual_machine_extension" "ama_linux" {
  count                      = var.enable_update_manager || var.enable_security_baseline ? 1 : 0
  name                       = "AzureMonitorLinuxAgent"
  virtual_machine_id         = azurerm_linux_virtual_machine.main.id
  publisher                  = "Microsoft.Azure.Monitor"
  type                       = "AzureMonitorLinuxAgent"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true

  tags = local.common_tags
}

# Guest Configuration Extension for Linux (Security Baseline)
resource "azurerm_virtual_machine_extension" "guest_config_linux" {
  count                      = var.enable_guest_config ? 1 : 0
  name                       = "GuestConfigurationExtensionLinux"
  virtual_machine_id         = azurerm_linux_virtual_machine.main.id
  publisher                  = "Microsoft.GuestConfiguration"
  type                       = "ConfigurationforLinux"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true

  tags = local.common_tags

  depends_on = [
    azurerm_virtual_machine_extension.ama_linux
  ]
}

# Custom script for additional security hardening (Linux)
resource "azurerm_virtual_machine_extension" "hardening_script" {
  count                      = var.enable_security_baseline ? 1 : 0
  name                       = "HardeningScript"
  virtual_machine_id         = azurerm_linux_virtual_machine.main.id
  publisher                  = "Microsoft.Azure.Extensions"
  type                       = "CustomScript"
  type_handler_version       = "2.1"
  auto_upgrade_minor_version = true

  settings = jsonencode({
    commandToExecute = "bash -c 'apt-get update && apt-get install -y auditd aide aide-common && systemctl enable auditd && systemctl start auditd && apt-get install -y chrony && systemctl enable chrony && systemctl start chrony && echo \"vm.unprivileged_userns_clone=0\" >> /etc/sysctl.conf && sysctl -p'"
  })

  tags = local.common_tags

  depends_on = [
    azurerm_virtual_machine_extension.mma_linux
  ]
}

# Patch Assignment for Update Manager v2 (Linux)
resource "azurerm_resource_group_template_deployment" "patch_assignment" {
  count               = var.enable_update_manager ? 1 : 0
  name                = "patch-assign-${var.environment_name}"
  resource_group_name = azurerm_resource_group.main.name
  deployment_mode     = "Incremental"

  template_content = jsonencode({
    "$schema" = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
    "contentVersion" = "1.0.0.0"
    "resources" = [
      {
        "type" = "Microsoft.Compute/virtualMachines/providers/configurationProfileAssignments"
        "apiVersion" = "2023-12-01-preview"
        "name" = "${azurerm_linux_virtual_machine.main.name}/Microsoft.GuestConfiguration/default"
        "properties" = {
          "guestConfiguration" = {
            "name" = "LinuxUpdateManager"
            "assignmentType" = "ApplyAndMonitor"
            "configurationSetting" = {
              "assessmentMode" = var.patch_assessment_frequency
              "rebootSetting" = "IfRequired"
            }
          }
        }
      }
    ]
  })

  depends_on = [
    azurerm_linux_virtual_machine.main,
    azurerm_virtual_machine_extension.dependency_agent,
    azurerm_virtual_machine_extension.ama_linux
  ]
}

# Outputs
output "vm_id" {
  value       = azurerm_linux_virtual_machine.main.id
}

output "vm_name" {
  description = "Name of the created VM"
  value       = azurerm_linux_virtual_machine.main.name
}

output "public_ip_address" {
  description = "Public IP address of the VM"
  value       = azurerm_public_ip.main.ip_address
}

output "private_ip_address" {
  description = "Private IP address of the VM"
  value       = azurerm_network_interface.main.private_ip_address
}

output "virtual_network_id" {
  description = "ID of the virtual network"
  value       = azurerm_virtual_network.main.id
}

output "resource_group_name" {
  description = "Name of the resource group"
  value       = azurerm_resource_group.main.name
}

output "resource_group_id" {
  description = "ID of the resource group"
  value       = azurerm_resource_group.main.id
}

output "security_and_compliance_status" {
  value = {
    security_baseline_enabled   = var.enable_security_baseline
    update_manager_enabled      = var.enable_update_manager
    guest_configuration_enabled = var.enable_guest_config
    monitoring_enabled          = var.enable_update_manager || var.enable_security_baseline
  }
  description = "Security and compliance configuration status"
}

output "monitoring_resources" {
  value = var.enable_security_baseline || var.enable_update_manager ? {
    log_analytics_workspace_id   = var.enable_security_baseline ? azurerm_log_analytics_workspace.law[0].id : null
    log_analytics_workspace_name = var.enable_security_baseline ? azurerm_log_analytics_workspace.law[0].name : null
    patch_assessment_frequency   = var.patch_assessment_frequency
    update_manager_v2_enabled    = var.enable_update_manager
  } : null
  description = "Monitoring and compliance resources"
}

output "vm_extensions_deployed" {
  value = var.enable_security_baseline || var.enable_update_manager ? [
    "DependencyAgentLinux",
    "AzureMonitorLinuxAgent (v2)",
    var.enable_guest_config ? "GuestConfigurationExtensionLinux" : null,
    var.enable_security_baseline ? "HardeningScript" : null,
    var.enable_update_manager ? "Update Manager v2 Assignment" : null
  ] : []
  description = "VM extensions and agents deployed for security and compliance"
}

output "security_compliance_commands" {
  value = var.enable_security_baseline || var.enable_update_manager ? {
    view_assessments     = "az maintenance assignment list --resource-group ${azurerm_resource_group.main.name}"
    view_update_status   = "az vm extension show --resource-group ${azurerm_resource_group.main.name} --vm-name vm-${var.environment_name} --name AzureMonitorLinuxAgent"
    view_compliance      = "az policy state list --resource-group ${azurerm_resource_group.main.name}"
    ssh_to_vm            = "ssh -i ~/.ssh/id_rsa ${var.admin_username}@${azurerm_public_ip.main.ip_address}"
  } : {}
  description = "Commands to view security and compliance status"
}

