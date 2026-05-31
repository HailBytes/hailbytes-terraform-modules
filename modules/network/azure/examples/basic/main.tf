terraform {
  required_version = ">= 1.5.0"
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

variable "resource_group_name" { type = string }
variable "location" {
  type    = string
  default = "eastus"
}

variable "name_prefix" {
  type    = string
  default = "hailbytes-prod"
}

variable "environment" {
  type    = string
  default = "prod"
}

module "network" {
  source = "../.."

  name_prefix         = var.name_prefix
  resource_group_name = var.resource_group_name
  location            = var.location

  tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# Wire these outputs into a workload module:
#   module "hailbytes_asm" {
#     source                  = "github.com/hailbytes/hailbytes-terraform-modules//asm-azure-ha"
#     resource_group_name     = var.resource_group_name
#     location                = var.location
#     vnet_id                 = module.network.vnet_id
#     vm_subnet_id            = module.network.workload_subnet_id
#     lb_subnet_id            = module.network.lb_subnet_id
#     db_delegated_subnet_id  = module.network.db_delegated_subnet_id
#     private_dns_zone_id     = module.network.private_dns_zone_id
#     ...
#   }

output "vnet_id" {
  description = "Pass to var.vnet_id on workload modules."
  value       = module.network.vnet_id
}

output "workload_subnet_id" {
  description = "Pass to var.subnet_id (single-vm) or var.vm_subnet_id (ha-hot-hot, unlimited-scale)."
  value       = module.network.workload_subnet_id
}

output "lb_subnet_id" {
  description = "Pass to var.lb_subnet_id on ha-hot-hot / unlimited-scale modules."
  value       = module.network.lb_subnet_id
}

output "db_delegated_subnet_id" {
  description = "Pass to var.db_delegated_subnet_id on ha-hot-hot / unlimited-scale modules."
  value       = module.network.db_delegated_subnet_id
}

output "private_dns_zone_id" {
  description = "Pass to var.private_dns_zone_id on ha-hot-hot / unlimited-scale modules."
  value       = module.network.private_dns_zone_id
}
