# HailBytes SAT on Azure, HA hot-hot tier: complete quickstart.
#
# This root config provisions EVERYTHING, including the networking
# prerequisites (vnet, workload subnet, delegated Postgres subnet,
# private DNS zone) that the workload module otherwise expects you
# to bring. Subscribe to the HailBytes SAT Azure Marketplace listing
# first, set two variables in terraform.tfvars, then:
#
#   terraform init && terraform apply
#
# Deploying ASM instead? Change the module source below to
# ../../modules/asm-azure-ha and update name_prefix.

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.0, < 5.0"
    }
  }
}

provider "azurerm" {
  features {}
}

variable "resource_group_name" {
  description = "Resource group to create. All quickstart resources live here."
  type        = string
  default     = "rg-hailbytes-sat-prod"
}

variable "location" {
  description = "Azure region. northeurope = Dublin, eastus = Virginia."
  type        = string
  default     = "northeurope"
}

variable "allowed_cidrs" {
  description = "CIDRs allowed to reach the admin UI over HTTPS (e.g. your office egress IP as x.x.x.x/32)."
  type        = list(string)
}

variable "ssh_public_key" {
  description = "SSH public key for VM admin access (contents of ~/.ssh/id_ed25519.pub)."
  type        = string
}

variable "admin_username" {
  type    = string
  default = "hbadmin"
}

variable "environment" {
  type    = string
  default = "prod"
}

resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
}

# Networking prerequisites: vnet, workload/LB subnets, subnet delegated
# to Postgres Flexible Server, and the privatelink Postgres DNS zone.
module "network" {
  source = "../../modules/network/azure"

  name_prefix         = "hailbytes-sat-${var.environment}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  # The workload module associates its own NSGs; Azure allows one NSG
  # per subnet, so the network module must not attach its baseline set.
  associate_subnet_nsgs = false
}

module "hailbytes_sat" {
  source = "../../modules/sat-azure-ha"

  environment            = var.environment
  resource_group_name    = azurerm_resource_group.main.name
  location               = azurerm_resource_group.main.location
  vm_subnet_id           = module.network.workload_subnet_id
  lb_subnet_id           = module.network.lb_subnet_id
  db_delegated_subnet_id = module.network.db_delegated_subnet_id
  private_dns_zone_id    = module.network.private_dns_zone_id
  allowed_cidrs          = var.allowed_cidrs
  admin_username         = var.admin_username
  ssh_public_key         = var.ssh_public_key
}

output "load_balancer_public_ip" {
  description = "Point your browser at https://<this IP>/ once apply completes."
  value       = module.hailbytes_sat.load_balancer_public_ip
}

output "vm_ids" {
  value = module.hailbytes_sat.vm_ids
}

output "postgres_fqdn" {
  value = module.hailbytes_sat.postgres_fqdn
}

output "key_vault_uri" {
  description = "The DB password is stored here under secret name 'hailbytes-db-password'."
  value       = module.hailbytes_sat.key_vault_uri
}
