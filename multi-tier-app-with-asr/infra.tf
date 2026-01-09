terraform {
  required_version = ">= 1.3.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.0"
    }
    random = {
      source  = "hashicorp/random"
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

variable "primary_location" {
  type        = string
  description = "Primary Azure region for resources"
  default     = "eastus"
}

variable "secondary_location" {
  type        = string
  description = "Secondary region for ASR failover (if ASR enabled)"
  default     = "westus"
}

variable "enable_asr" {
  type        = bool
  description = "Enable Azure Site Recovery for failover capability"
  default     = true
}

variable "num_tiers" {
  type        = number
  description = "Number of application tiers (2 or 3)"
  default     = 3
}

variable "num_instances_per_tier" {
  type        = number
  description = "Number of App Service instances per tier"
  default     = 2
}

variable "tier_sku_configs" {
  type = map(object({
    tier = string
    size = string
  }))
  description = "SKU configuration for each tier"
  default = {
    tier1 = { tier = "Standard", size = "S1" }
    tier2 = { tier = "Standard", size = "S1" }
    tier3 = { tier = "Standard", size = "S1" }
  }
}

variable "enable_app_insights" {
  type        = bool
  description = "Enable Application Insights for monitoring"
  default     = true
}

variable "runtime_stack" {
  type        = string
  description = "Application runtime stack"
  default     = "NODE"
}

variable "runtime_version" {
  type        = string
  description = "Application runtime version"
  default     = "18-lts"
}

variable "db_admin_username" {
  type        = string
  description = "SQL Database administrator username"
  default     = "azadmin"
}

variable "db_admin_password" {
  type        = string
  description = "SQL Database administrator password"
  sensitive   = true
  validation {
    condition = (
      length(var.db_admin_password) >= 8 &&
      can(regex("[A-Z]", var.db_admin_password)) &&
      can(regex("[a-z]", var.db_admin_password)) &&
      can(regex("[0-9]", var.db_admin_password))
    )
    error_message = "Password must be at least 8 characters with uppercase, lowercase, and numbers."
  }
}

# Random suffix for unique names
resource "random_string" "unique" {
  length  = 4
  special = false
  upper   = false
}

# Primary Region Resources
resource "azurerm_resource_group" "primary" {
  name     = "${var.environment_name}-primary-rg"
  location = var.primary_location

  tags = {
    Environment = var.environment_name
    Region      = "primary"
    CreatedBy   = "ADE"
  }
}

# Secondary Region Resources (if ASR enabled)
resource "azurerm_resource_group" "secondary" {
  count    = var.enable_asr ? 1 : 0
  name     = "${var.environment_name}-secondary-rg"
  location = var.secondary_location

  tags = {
    Environment = var.environment_name
    Region      = "secondary"
    CreatedBy   = "ADE"
  }
}

# Primary Virtual Networks
resource "azurerm_virtual_network" "primary" {
  name                = "${var.environment_name}-primary-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.primary.location
  resource_group_name = azurerm_resource_group.primary.name
}

resource "azurerm_subnet" "primary_tier_subnets" {
  count                = var.num_tiers
  name                 = "tier-${count.index + 1}-subnet"
  resource_group_name  = azurerm_resource_group.primary.name
  virtual_network_name = azurerm_virtual_network.primary.name
  address_prefixes     = ["10.0.${count.index + 1}.0/24"]
}

# Secondary Virtual Networks (if ASR enabled)
resource "azurerm_virtual_network" "secondary" {
  count               = var.enable_asr ? 1 : 0
  name                = "${var.environment_name}-secondary-vnet"
  address_space       = ["10.1.0.0/16"]
  location            = azurerm_resource_group.secondary[0].location
  resource_group_name = azurerm_resource_group.secondary[0].name
}

resource "azurerm_subnet" "secondary_tier_subnets" {
  count                = var.enable_asr ? var.num_tiers : 0
  name                 = "tier-${count.index + 1}-subnet"
  resource_group_name  = azurerm_resource_group.secondary[0].name
  virtual_network_name = azurerm_virtual_network.secondary[0].name
  address_prefixes     = ["10.1.${count.index + 1}.0/24"]
}

# Primary SQL Server
resource "azurerm_mssql_server" "primary" {
  name                         = "${var.environment_name}-primary-sql-${random_string.unique.result}"
  resource_group_name          = azurerm_resource_group.primary.name
  location                     = azurerm_resource_group.primary.location
  version                      = "12.0"
  administrator_login          = var.db_admin_username
  administrator_login_password = var.db_admin_password

  tags = {
    Environment = var.environment_name
    Region      = "primary"
  }
}

# Primary SQL Databases (one per tier)
resource "azurerm_mssql_database" "primary_tier_dbs" {
  count           = var.num_tiers
  name            = "tier-${count.index + 1}-db"
  server_id       = azurerm_mssql_server.primary.id
  collation       = "SQL_Latin1_General_CP1_CI_AS"
  license_type    = "LicenseIncluded"
  sku_name        = "Standard"
  zone_redundant  = true

  tags = {
    Environment = var.environment_name
    Tier        = "tier-${count.index + 1}"
  }
}

# Secondary SQL Server (if ASR enabled) - for failover
resource "azurerm_mssql_server" "secondary" {
  count                        = var.enable_asr ? 1 : 0
  name                         = "${var.environment_name}-secondary-sql-${random_string.unique.result}"
  resource_group_name          = azurerm_resource_group.secondary[0].name
  location                     = azurerm_resource_group.secondary[0].location
  version                      = "12.0"
  administrator_login          = var.db_admin_username
  administrator_login_password = var.db_admin_password

  tags = {
    Environment = var.environment_name
    Region      = "secondary"
  }
}

# Failover Group for SQL databases
resource "azurerm_sql_failover_group" "primary" {
  count                     = var.enable_asr ? 1 : 0
  name                      = "${var.environment_name}-failover-group"
  server_name               = azurerm_mssql_server.primary.name
  resource_group_name       = azurerm_resource_group.primary.name
  partner_server_id         = azurerm_mssql_server.secondary[0].id
  database_ids              = [for db in azurerm_mssql_database.primary_tier_dbs : db.id]
  readonly_endpoint_failover_policy_enabled = true

  read_write_endpoint_failover_policy {
    mode          = "Automatic"
    grace_minutes = 60
  }

  tags = {
    Environment = var.environment_name
  }
}

# Firewall rules - allow Azure services
resource "azurerm_mssql_firewall_rule" "primary_allow_azure" {
  name             = "AllowAzureServices"
  server_id        = azurerm_mssql_server.primary.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

resource "azurerm_mssql_firewall_rule" "secondary_allow_azure" {
  count            = var.enable_asr ? 1 : 0
  name             = "AllowAzureServices"
  server_id        = azurerm_mssql_server.secondary[0].id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

# VNet integration firewall rules for primary
resource "azurerm_mssql_firewall_rule" "primary_vnet_rules" {
  count            = var.num_tiers
  name             = "AllowTier${count.index + 1}Subnet"
  server_id        = azurerm_mssql_server.primary.id
  start_ip_address = "10.0.${count.index + 1}.0"
  end_ip_address   = "10.0.${count.index + 1}.255"
}

# Primary Service Plans
resource "azurerm_service_plan" "primary_tier_plans" {
  count               = var.num_tiers
  name                = "${var.environment_name}-primary-tier-${count.index + 1}-plan"
  location            = azurerm_resource_group.primary.location
  resource_group_name = azurerm_resource_group.primary.name
  os_type             = "Linux"
  sku_name            = "${var.tier_sku_configs["tier${count.index + 1}"].tier}${var.tier_sku_configs["tier${count.index + 1}"].size}"

  tags = {
    Environment = var.environment_name
    Tier        = "tier-${count.index + 1}"
  }
}

# Primary Web Apps
resource "azurerm_linux_web_app" "primary_tier_apps" {
  count               = var.num_tiers
  name                = "${var.environment_name}-primary-tier-${count.index + 1}-${random_string.unique.result}"
  location            = azurerm_resource_group.primary.location
  resource_group_name = azurerm_resource_group.primary.name
  service_plan_id     = azurerm_service_plan.primary_tier_plans[count.index].id

  site_config {
    application_stack {
      docker_registry_url      = "DOCKER|"
      docker_image_name        = "nginx:latest"
      docker_registry_username = ""
      docker_registry_password = ""
    }
    minimum_tls_version = "1.2"
    http2_enabled       = true
  }

  app_settings = {
    WEBSITES_ENABLE_APP_SERVICE_STORAGE = "false"
    TIER                                 = "tier-${count.index + 1}"
    ENVIRONMENT                          = var.environment_name
    APPINSIGHTS_INSTRUMENTATIONKEY       = var.enable_app_insights ? azurerm_application_insights.primary[0].instrumentation_key : ""
    APPLICATIONINSIGHTS_CONNECTION_STRING = var.enable_app_insights ? azurerm_application_insights.primary[0].connection_string : ""
  }

  tags = {
    Environment = var.environment_name
    Tier        = "tier-${count.index + 1}"
    Region      = "primary"
  }
}

# Secondary Service Plans (if ASR enabled)
resource "azurerm_service_plan" "secondary_tier_plans" {
  count               = var.enable_asr ? var.num_tiers : 0
  name                = "${var.environment_name}-secondary-tier-${count.index + 1}-plan"
  location            = azurerm_resource_group.secondary[0].location
  resource_group_name = azurerm_resource_group.secondary[0].name
  os_type             = "Linux"
  sku_name            = "${var.tier_sku_configs["tier${count.index + 1}"].tier}${var.tier_sku_configs["tier${count.index + 1}"].size}"

  tags = {
    Environment = var.environment_name
    Tier        = "tier-${count.index + 1}"
  }
}

# Secondary Web Apps (if ASR enabled)
resource "azurerm_linux_web_app" "secondary_tier_apps" {
  count               = var.enable_asr ? var.num_tiers : 0
  name                = "${var.environment_name}-secondary-tier-${count.index + 1}-${random_string.unique.result}"
  location            = azurerm_resource_group.secondary[0].location
  resource_group_name = azurerm_resource_group.secondary[0].name
  service_plan_id     = azurerm_service_plan.secondary_tier_plans[count.index].id

  site_config {
    application_stack {
      docker_registry_url      = "DOCKER|"
      docker_image_name        = "nginx:latest"
      docker_registry_username = ""
      docker_registry_password = ""
    }
    minimum_tls_version = "1.2"
    http2_enabled       = true
  }

  app_settings = {
    WEBSITES_ENABLE_APP_SERVICE_STORAGE = "false"
    TIER                                 = "tier-${count.index + 1}"
    ENVIRONMENT                          = var.environment_name
    APPINSIGHTS_INSTRUMENTATIONKEY       = var.enable_app_insights ? azurerm_application_insights.secondary[0].instrumentation_key : ""
    APPLICATIONINSIGHTS_CONNECTION_STRING = var.enable_app_insights ? azurerm_application_insights.secondary[0].connection_string : ""
  }

  tags = {
    Environment = var.environment_name
    Tier        = "tier-${count.index + 1}"
    Region      = "secondary"
  }
}

# Application Insights - Primary
resource "azurerm_application_insights" "primary" {
  count               = var.enable_app_insights ? 1 : 0
  name                = "${var.environment_name}-primary-appinsights"
  location            = azurerm_resource_group.primary.location
  resource_group_name = azurerm_resource_group.primary.name
  application_type    = "web"

  tags = {
    Environment = var.environment_name
    Region      = "primary"
  }
}

# Application Insights - Secondary
resource "azurerm_application_insights" "secondary" {
  count               = var.enable_app_insights && var.enable_asr ? 1 : 0
  name                = "${var.environment_name}-secondary-appinsights"
  location            = azurerm_resource_group.secondary[0].location
  resource_group_name = azurerm_resource_group.secondary[0].name
  application_type    = "web"

  tags = {
    Environment = var.environment_name
    Region      = "secondary"
  }
}

# Outputs
output "resource_group_names" {
  value = {
    primary   = azurerm_resource_group.primary.name
    secondary = var.enable_asr ? azurerm_resource_group.secondary[0].name : "N/A"
  }
  description = "Primary and secondary resource group names"
}

output "sql_servers" {
  value = {
    primary_fqdn   = azurerm_mssql_server.primary.fully_qualified_domain_name
    secondary_fqdn = var.enable_asr ? azurerm_mssql_server.secondary[0].fully_qualified_domain_name : "N/A"
    failover_group = var.enable_asr ? azurerm_sql_failover_group.primary[0].name : "N/A"
  }
  description = "SQL Server details"
}

output "databases" {
  value = {
    for idx, db in azurerm_mssql_database.primary_tier_dbs : "tier_${idx + 1}" => {
      id   = db.id
      name = db.name
    }
  }
  description = "Tier database information"
}

output "primary_web_apps" {
  value = {
    for idx, app in azurerm_linux_web_app.primary_tier_apps : "tier_${idx + 1}" => {
      id           = app.id
      default_url  = "https://${app.default_hostname}"
      hostname     = app.default_hostname
      site_config  = app.site_config
    }
  }
  description = "Primary region Web App details"
}

output "secondary_web_apps" {
  value = var.enable_asr ? {
    for idx, app in azurerm_linux_web_app.secondary_tier_apps : "tier_${idx + 1}" => {
      id           = app.id
      default_url  = "https://${app.default_hostname}"
      hostname     = app.default_hostname
    }
  } : null
  description = "Secondary region Web App details (for ASR failover)"
}

output "app_insights" {
  value = var.enable_app_insights ? {
    primary = {
      instrumentation_key = azurerm_application_insights.primary[0].instrumentation_key
      app_id             = azurerm_application_insights.primary[0].app_id
    }
    secondary = var.enable_asr ? {
      instrumentation_key = azurerm_application_insights.secondary[0].instrumentation_key
      app_id             = azurerm_application_insights.secondary[0].app_id
    } : null
  } : null
  description = "Application Insights details"
}

output "configuration_summary" {
  value = {
    environment_name        = var.environment_name
    primary_location        = var.primary_location
    secondary_location      = var.secondary_location
    asr_enabled             = var.enable_asr
    num_tiers               = var.num_tiers
    instances_per_tier      = var.num_instances_per_tier
    app_insights_enabled    = var.enable_app_insights
    failover_group_endpoint = var.enable_asr ? azurerm_sql_failover_group.primary[0].name : "N/A"
  }
  description = "Complete deployment configuration summary"
}

output "connection_strings" {
  value = {
    for idx, db in azurerm_mssql_database.primary_tier_dbs :
    "tier_${idx + 1}" => "Server=tcp:${azurerm_mssql_server.primary.fully_qualified_domain_name},1433;Initial Catalog=${db.name};Persist Security Info=False;User ID=${var.db_admin_username};Password=<PASSWORD>;MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"
  }
  sensitive   = true
  description = "SQL connection strings for tier databases (replace <PASSWORD> with actual password)"
}
