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
  # Terraform's azurerm provider defaults to registering ~70 resource providers
  # on every apply. Registration is a SUBSCRIPTION-scoped write
  # (*/register/action) that most delegated service principals and many
  # least-privilege operator roles do not hold, so the apply fails closed with
  # a wall of 403s before creating anything -- including for providers this
  # stack never touches (Microsoft.BotService, Microsoft.HealthcareApis, ...).
  #
  # Turning it off makes the failure mode explicit instead: register the
  # handful of providers this module actually needs, once, as a subscription
  # owner. See SECURITY-DEFAULTS.md, "Subscription prerequisites".
  resource_provider_registrations = "none"

  features {}
}

variable "resource_group_name" { type = string }
variable "location" {
  type    = string
  default = "eastus"
}
variable "subnet_id" { type = string }
variable "allowed_cidrs" { type = list(string) }
variable "admin_username" {
  type    = string
  default = "hbadmin"
}
variable "ssh_public_key" { type = string }
variable "environment" {
  type    = string
  default = "dev"
}

module "hailbytes_asm" {
  source = "../.."

  product             = "asm"
  environment         = var.environment
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.subnet_id
  allowed_cidrs       = var.allowed_cidrs
  admin_username      = var.admin_username
  ssh_public_key      = var.ssh_public_key
}

output "vm_id" { value = module.hailbytes_asm.vm_id }
output "vm_name" { value = module.hailbytes_asm.vm_name }
output "private_ip" { value = module.hailbytes_asm.private_ip_address }
output "console_url" { value = module.hailbytes_asm.console_url }
output "resource_group_name" { value = var.resource_group_name }
