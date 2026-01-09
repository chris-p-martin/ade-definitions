terraform {
  required_version = ">= 1.3.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

variable "environment_name" {
  type        = string
  description = "Name of the environment (used for resource naming)"
}

variable "location" {
  type        = string
  description = "Azure region for resources"
  default     = "eastus"
}

variable "num_tiers" {
  type        = number
  description = "Number of application tiers (2 or 3)"
  default     = 3
}

variable "vms_per_tier" {
  type        = number
  description = "Number of VMs per tier"
  default     = 2
}

variable "vm_size" {
  type        = string
  description = "VM size (e.g., Standard_B2s, Standard_D2s_v3)"
  default     = "Standard_B2s"
}

variable "os_publisher" {
  type        = string
  description = "OS publisher"
  default     = "Canonical"
}

variable "os_offer" {
  type        = string
  description = "OS offer"
  default     = "0001-com-ubuntu-server-focal"
}

variable "os_sku" {
  type        = string
  description = "OS SKU"
  default     = "20_04-lts-gen2"
}

variable "os_version" {
  type        = string
  description = "OS version"
  default     = "latest"
}

variable "admin_username" {
  type        = string
  description = "Admin username for VMs"
  default     = "azureuser"
}

variable "ssh_public_key_path" {
  type        = string
  description = "Path to SSH public key"
  default     = "~/.ssh/id_rsa.pub"
}

variable "enable_security_baseline" {
  type        = bool
  description = "Enable Azure security baselines and compliance on VMs"
  default     = true
}

variable "enable_update_manager" {
  type        = bool
  description = "Enable Azure Update Manager v2 for patch management"
  default     = true
}

variable "patch_assessment_frequency" {
  type        = string
  description = "Frequency of patch assessments for Update Manager v2"
  default     = "Weekly"
  validation {
    condition     = contains(["Daily", "Weekly", "Monthly"], var.patch_assessment_frequency)
    error_message = "patch_assessment_frequency must be Daily, Weekly, or Monthly"
  }
}

variable "patch_assessment_frequency" {
  type        = string
  description = "Frequency for patch assessments: Daily, Weekly, Monthly"
  default     = "Weekly"
}

variable "enable_guest_config" {
  type        = bool
  description = "Enable Azure Guest Configuration for compliance monitoring"
  default     = true
}

# Get availability zones for the region
data "azurerm_availability_zones" "available" {
  provider = azurerm

  location           = var.location
  supported_resource_types = ["VirtualMachine"]
}

# Get current Azure context for resource naming
data "azurerm_client_config" "current" {}

# Resource Group
resource "azurerm_resource_group" "rg" {
  name     = "${var.environment_name}-rg"
  location = var.location

  tags = {
    Environment = var.environment_name
    CreatedBy   = "ADE"
    CreatedDate = timestamp()
  }
}

# Virtual Network with multiple subnets (one per tier)
resource "azurerm_virtual_network" "vnet" {
  name                = "${var.environment_name}-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  tags = {
    Environment = var.environment_name
  }
}

# Subnets - one for each tier
resource "azurerm_subnet" "tier_subnets" {
  count                = var.num_tiers
  name                 = "tier-${count.index + 1}-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.${count.index + 1}.0/24"]
}

# Network Security Groups - one per tier
resource "azurerm_network_security_group" "tier_nsgs" {
  count               = var.num_tiers
  name                = "${var.environment_name}-tier-${count.index + 1}-nsg"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  tags = {
    Environment = var.environment_name
    Tier        = "tier-${count.index + 1}"
  }
}

# SSH access from internet to tier 1 (web tier)
resource "azurerm_network_security_rule" "ssh_tier1" {
  name                        = "AllowSSHFromInternet"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.tier_nsgs[0].name
}

# HTTP/HTTPS access to tier 1
resource "azurerm_network_security_rule" "http_tier1" {
  name                        = "AllowHTTPFromInternet"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "80"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.tier_nsgs[0].name
}

resource "azurerm_network_security_rule" "https_tier1" {
  name                        = "AllowHTTPSFromInternet"
  priority                    = 120
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.tier_nsgs[0].name
}

# Inter-tier communication rules (allow from previous tier to current tier)
resource "azurerm_network_security_rule" "inter_tier" {
  count                       = var.num_tiers > 1 ? var.num_tiers - 1 : 0
  name                        = "AllowFromTier${count.index + 1}"
  priority                    = 200 + count.index
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = azurerm_subnet.tier_subnets[count.index].address_prefixes[0]
  destination_address_prefix  = azurerm_subnet.tier_subnets[count.index + 1].address_prefixes[0]
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.tier_nsgs[count.index + 1].name
}

# Associate NSGs with subnets
resource "azurerm_subnet_network_security_group_association" "tier_nsg_assoc" {
  count                     = var.num_tiers
  subnet_id                 = azurerm_subnet.tier_subnets[count.index].id
  network_security_group_id = azurerm_network_security_group.tier_nsgs[count.index].id
}

# Network Interfaces for VMs (distributed across AZs)
resource "azurerm_network_interface" "tier_nics" {
  count               = var.num_tiers * var.vms_per_tier
  name                = "${var.environment_name}-tier-${floor(count.index / var.vms_per_tier) + 1}-vm-${count.index % var.vms_per_tier + 1}-nic"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "testConfiguration"
    subnet_id                     = azurerm_subnet.tier_subnets[floor(count.index / var.vms_per_tier)].id
    private_ip_address_allocation = "Dynamic"
  }

  tags = {
    Environment = var.environment_name
    Tier        = "tier-${floor(count.index / var.vms_per_tier) + 1}"
  }
}

# Public IPs for tier 1 VMs only (web tier)
resource "azurerm_public_ip" "tier1_pips" {
  count               = var.vms_per_tier
  name                = "${var.environment_name}-tier-1-vm-${count.index + 1}-pip"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"

  tags = {
    Environment = var.environment_name
    Tier        = "tier-1"
  }
}

# Associate Public IPs with tier 1 NICs
resource "azurerm_network_interface_public_ip_association" "tier1_pip_assoc" {
  count                    = var.vms_per_tier
  network_interface_id     = azurerm_network_interface.tier_nics[count.index].id
  public_ip_address_id     = azurerm_public_ip.tier1_pips[count.index].id
}

# Virtual Machines - distributed across availability zones
resource "azurerm_linux_virtual_machine" "tier_vms" {
  count                 = var.num_tiers * var.vms_per_tier
  name                  = "${var.environment_name}-tier-${floor(count.index / var.vms_per_tier) + 1}-vm-${count.index % var.vms_per_tier + 1}"
  location              = azurerm_resource_group.rg.location
  resource_group_name   = azurerm_resource_group.rg.name
  size                  = var.vm_size
  zone                  = data.azurerm_availability_zones.available.zones[count.index % length(data.azurerm_availability_zones.available.zones)]

  admin_username = var.admin_username

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(expanduser(var.ssh_public_key_path))
  }

  network_interface_ids = [
    azurerm_network_interface.tier_nics[count.index].id,
  ]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  source_image_reference {
    publisher = var.os_publisher
    offer     = var.os_offer
    sku       = var.os_sku
    version   = var.os_version
  }

  tags = {
    Environment = var.environment_name
    Tier        = "tier-${floor(count.index / var.vms_per_tier) + 1}"
    AZ          = data.azurerm_availability_zones.available.zones[count.index % length(data.azurerm_availability_zones.available.zones)]
  }

  depends_on = [
    azurerm_network_interface.tier_nics
  ]
}

# Storage account for Update Manager and diagnostic data
resource "azurerm_storage_account" "diag" {
  count                    = var.enable_update_manager || var.enable_security_baseline ? 1 : 0
  name                     = replace("${var.environment_name}diag", "-", "")
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  tags = {
    Environment = var.environment_name
  }
}

# Log Analytics Workspace for Update Manager and compliance monitoring
resource "azurerm_log_analytics_workspace" "law" {
  count               = var.enable_update_manager || var.enable_security_baseline ? 1 : 0
  name                = "${var.environment_name}-law"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30

  tags = {
    Environment = var.environment_name
  }
}



# Dependency Agent Extension for Update Manager v2 (Linux)
resource "azurerm_virtual_machine_extension" "dependency_agent" {
  count                      = var.enable_update_manager ? (var.num_tiers * var.vms_per_tier) : 0
  name                       = "DependencyAgentLinux"
  virtual_machine_id         = azurerm_linux_virtual_machine.tier_vms[count.index].id
  publisher                  = "Microsoft.Azure.Monitoring.DependencyAgent"
  type                       = "DependencyAgentLinux"
  type_handler_version       = "9.10"
  auto_upgrade_minor_version = true

  settings = jsonencode({
    enableAMA = true
  })

  tags = {
    Environment = var.environment_name
  }
}

# Azure Monitor Agent Extension for Update Manager v2 and security baseline (Linux)
resource "azurerm_virtual_machine_extension" "ama_linux" {
  count                      = var.enable_update_manager || var.enable_security_baseline ? (var.num_tiers * var.vms_per_tier) : 0
  name                       = "AzureMonitorLinuxAgent"
  virtual_machine_id         = azurerm_linux_virtual_machine.tier_vms[count.index].id
  publisher                  = "Microsoft.Azure.Monitor"
  type                       = "AzureMonitorLinuxAgent"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true

  tags = {
    Environment = var.environment_name
  }
}

# Guest Configuration Extension for Linux (Security Baseline)
resource "azurerm_virtual_machine_extension" "guest_config_linux" {
  count                      = var.enable_guest_config ? (var.num_tiers * var.vms_per_tier) : 0
  name                       = "GuestConfigurationExtensionLinux"
  virtual_machine_id         = azurerm_linux_virtual_machine.tier_vms[count.index].id
  publisher                  = "Microsoft.GuestConfiguration"
  type                       = "ConfigurationforLinux"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true

  tags = {
    Environment = var.environment_name
  }

  depends_on = [
    azurerm_virtual_machine_extension.ama_linux
  ]
}

# Patch Assignments for Update Manager v2 (Linux)
resource "azurerm_resource_group_template_deployment" "patch_assignments" {
  count               = var.enable_update_manager ? 1 : 0
  name                = "patch-assign-${var.environment_name}"
  resource_group_name = azurerm_resource_group.rg.name
  deployment_mode     = "Incremental"

  template_content = jsonencode({
    "$schema" = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
    "contentVersion" = "1.0.0.0"
    "resources" = [
      for idx, vm_id in azurerm_linux_virtual_machine.tier_vms[*].id : {
        "type" = "Microsoft.Compute/virtualMachines/providers/configurationProfileAssignments"
        "apiVersion" = "2023-12-01-preview"
        "name" = "${azurerm_linux_virtual_machine.tier_vms[idx].name}/Microsoft.GuestConfiguration/default"
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
    azurerm_linux_virtual_machine.tier_vms,
    azurerm_virtual_machine_extension.dependency_agent,
    azurerm_virtual_machine_extension.ama_linux
  ]
}

# Azure Policy - Linux Security Baseline
resource "azurerm_resource_group_policy_assignment" "linux_baseline" {
  count              = var.enable_security_baseline ? 1 : 0
  name               = "${var.environment_name}-linux-baseline"
  policy_definition_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Authorization/policyDefinitions/fc1665f9-d66e-4a1b-b37d-a7547666522e"
  resource_group_id  = azurerm_resource_group.rg.id

  parameters = jsonencode({
    effect = {
      value = "Audit"
    }
  })

  depends_on = [
    azurerm_linux_virtual_machine.tier_vms
  ]
}

# Custom script for additional security hardening (Linux)
resource "azurerm_virtual_machine_extension" "hardening_script" {
  count                      = var.enable_security_baseline ? (var.num_tiers * var.vms_per_tier) : 0
  name                       = "HardeningScript"
  virtual_machine_id         = azurerm_linux_virtual_machine.tier_vms[count.index].id
  publisher                  = "Microsoft.Azure.Extensions"
  type                       = "CustomScript"
  type_handler_version       = "2.1"
  auto_upgrade_minor_version = true

  settings = jsonencode({
    commandToExecute = "bash -c 'apt-get update && apt-get install -y auditd aide aide-common && systemctl enable auditd && systemctl start auditd && apt-get install -y chrony && systemctl enable chrony && systemctl start chrony && echo \"vm.unprivileged_userns_clone=0\" >> /etc/sysctl.conf && sysctl -p'"
  })

  tags = {
    Environment = var.environment_name
  }

  depends_on = [
    azurerm_virtual_machine_extension.mma_linux
  ]
}

# Virtual machine extensions summary
resource "null_resource" "vm_config_summary" {
  count = var.num_tiers * var.vms_per_tier

  triggers = {
    vm_id                = azurerm_linux_virtual_machine.tier_vms[count.index].id
    update_manager       = var.enable_update_manager ? "enabled" : "disabled"
    security_baseline    = var.enable_security_baseline ? "enabled" : "disabled"
    guest_config         = var.enable_guest_config ? "enabled" : "disabled"
  }
}

# Outputs
output "resource_group_name" {
  value       = azurerm_resource_group.rg.name
  description = "Name of the resource group"
}

output "resource_group_id" {
  value       = azurerm_resource_group.rg.id
  description = "ID of the resource group"
}

output "virtual_network_id" {
  value       = azurerm_virtual_network.vnet.id
  description = "ID of the virtual network"
}

output "tier_subnets" {
  value = {
    for idx, subnet in azurerm_subnet.tier_subnets : "tier_${idx + 1}" => {
      id   = subnet.id
      name = subnet.name
    }
  }
  description = "Tier subnets information"
}

output "tier_vm_ids" {
  value = {
    for idx, vm in azurerm_linux_virtual_machine.tier_vms : "${floor(idx / var.vms_per_tier) + 1}_vm_${idx % var.vms_per_tier + 1}" => vm.id
  }
  description = "VM IDs by tier"
}

output "tier_1_public_ips" {
  value = {
    for idx, pip in azurerm_public_ip.tier1_pips : "vm_${idx + 1}" => pip.ip_address
  }
  description = "Public IP addresses for tier 1 VMs"
}

output "tier_1_private_ips" {
  value = {
    for idx, nic in slice(azurerm_network_interface.tier_nics, 0, var.vms_per_tier) : "vm_${idx + 1}" => nic.private_ip_address
  }
  description = "Private IP addresses for tier 1 VMs"
}

output "tier_vm_details" {
  value = {
    for idx, vm in azurerm_linux_virtual_machine.tier_vms : vm.name => {
      id                = vm.id
      zone              = vm.availability_zone
      private_ip        = vm.private_ip_addresses[0]
      public_ip         = idx < var.vms_per_tier ? azurerm_public_ip.tier1_pips[idx % var.vms_per_tier].ip_address : null
      tier              = floor(idx / var.vms_per_tier) + 1
      admin_username    = var.admin_username
    }
  }
  description = "Complete VM details including IPs, zones, and tier information"
}

output "configuration_summary" {
  value = {
    num_tiers      = var.num_tiers
    vms_per_tier   = var.vms_per_tier
    total_vms      = var.num_tiers * var.vms_per_tier
    vm_size        = var.vm_size
    availability_zones = data.azurerm_availability_zones.available.zones
    admin_username = var.admin_username
  }
  description = "Summary of the deployment configuration"
}

output "security_and_compliance_status" {
  value = {
    security_baseline_enabled    = var.enable_security_baseline
    update_manager_enabled       = var.enable_update_manager
    guest_configuration_enabled  = var.enable_guest_config
    patch_assessment_frequency   = var.patch_assessment_frequency
    monitoring_enabled           = var.enable_update_manager || var.enable_security_baseline
  }
  description = "Security and compliance configuration status"
}

output "monitoring_resources" {
  value = var.enable_security_baseline ? {
    log_analytics_workspace_id   = azurerm_log_analytics_workspace.law[0].id
    log_analytics_workspace_name = azurerm_log_analytics_workspace.law[0].name
    storage_account_id           = azurerm_storage_account.diag[0].id
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
    view_assessments     = "az maintenance assignment list --resource-group ${azurerm_resource_group.rg.name}"
    view_update_status   = "az vm extension show --resource-group ${azurerm_resource_group.rg.name} --vm-name <vm-name> --name AzureMonitorLinuxAgent"
    view_compliance      = "az policy state list --resource-group ${azurerm_resource_group.rg.name}"
    view_patches_needed  = "az maintenance public-configuration list"
    ssh_to_vm            = "ssh -i ~/.ssh/id_rsa ${var.admin_username}@<tier-1-public-ip>"
  } : {}
  description = "Commands to view security and compliance status"
}

