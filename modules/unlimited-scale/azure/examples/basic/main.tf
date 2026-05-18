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
variable "vm_subnet_id" { type = string }
variable "db_delegated_subnet_id" { type = string }
variable "private_dns_zone_id" { type = string }
variable "allowed_cidrs" { type = list(string) }
variable "admin_username" {
  type    = string
  default = "hbadmin"
}
variable "ssh_public_key" { type = string }
variable "alert_email" {
  type    = string
  default = null
}
variable "environment" {
  type    = string
  default = "prod"
}

module "hailbytes_asm_scale" {
  source = "../.."

  product                = "asm"
  environment            = var.environment
  resource_group_name    = var.resource_group_name
  location               = var.location
  vm_subnet_id           = var.vm_subnet_id
  db_delegated_subnet_id = var.db_delegated_subnet_id
  private_dns_zone_id    = var.private_dns_zone_id
  allowed_cidrs          = var.allowed_cidrs
  admin_username         = var.admin_username
  ssh_public_key         = var.ssh_public_key
  alert_email            = var.alert_email
}

output "load_balancer_public_ip" { value = module.hailbytes_asm_scale.load_balancer_public_ip }
output "vmss_name" { value = module.hailbytes_asm_scale.vmss_name }
output "postgres_primary_fqdn" { value = module.hailbytes_asm_scale.postgres_primary_fqdn }
output "postgres_replica_fqdns" { value = module.hailbytes_asm_scale.postgres_replica_fqdns }
output "resource_group_name" { value = var.resource_group_name }
