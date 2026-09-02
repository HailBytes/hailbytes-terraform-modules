# HailBytes SAT on Azure, single-VM tier: complete quickstart.
#
# The fallback when the HA tier is not available or not yet warranted. One VM,
# its own public IP, and PostgreSQL running ON the VM -- no Flexible Server, no
# load balancer, no Key Vault plumbing for a shared password.
#
# That is the whole trade. It is materially simpler and cheaper to stand up, and
# it has no redundancy: a reboot is an outage, and the VM's local database is the
# single copy of your campaign history. Take backups.
#
# Subscribe to the HailBytes SAT Azure Marketplace listing, run
# ../preflight-azure.sh single, set two variables in terraform.tfvars, then:
#
#   terraform init && terraform apply
#
# Deploying ASM instead? Change the module source to ../../modules/asm-azure-single.

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
  # Same reasoning as the HA quickstart: the provider's default registration
  # sweep touches ~70 providers and is a SUBSCRIPTION-scoped write most
  # least-privilege operator roles do not hold, so an apply fails closed with a
  # wall of 403s before creating anything. Turning it off makes the requirement
  # explicit, and ../preflight-azure.sh is the explicit step.
  resource_provider_registrations = "none"

  features {}
}

variable "resource_group_name" {
  description = "Resource group to create. All quickstart resources live here."
  type        = string
  default     = "rg-hailbytes-sat-single"
}

variable "location" {
  description = "Azure region. northeurope = Dublin, eastus = Virginia."
  type        = string
  default     = "northeurope"
}

variable "allowed_cidrs" {
  description = "CIDRs allowed to reach the admin UI (e.g. your office egress IP as x.x.x.x/32). This tier puts a public IP directly on the VM, so keep this tight."
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

# The single-VM module needs exactly one subnet and brings no networking of its
# own. modules/network/azure emits more than this tier uses -- the delegated
# Postgres subnet and the privatelink DNS zone go unused here, because the
# database is local to the VM. Reusing the module anyway keeps one definition of
# the baseline network across both tiers rather than two that drift.
module "network" {
  source = "../../modules/network/azure"

  name_prefix         = "hailbytes-sat-${var.environment}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  # The workload module associates its own NSG, and Azure allows one NSG per
  # subnet, so the network module must not attach its baseline set. The flag
  # also stops those NSGs being created at all, which matters here because the
  # workload module's load-balancer NSG carries the same name.
  associate_subnet_nsgs = false
}

module "hailbytes_sat" {
  source = "../../modules/sat-azure-single"

  environment         = var.environment
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  subnet_id           = module.network.workload_subnet_id
  allowed_cidrs       = var.allowed_cidrs
  admin_username      = var.admin_username
  ssh_public_key      = var.ssh_public_key
}

output "console_url" {
  description = "Admin UI. The certificate is self-signed on first boot, so expect a browser warning."
  value       = module.hailbytes_sat.console_url
}

output "public_ip_address" {
  value = module.hailbytes_sat.public_ip_address
}

output "vm_name" {
  description = "Use with 'az vm run-command invoke' to read the initial credentials file."
  value       = module.hailbytes_sat.vm_name
}

output "initial_credentials_command" {
  description = "Prints the initial admin password from inside the VM."
  value = join(" ", [
    "az vm run-command invoke -g", azurerm_resource_group.main.name,
    "-n", module.hailbytes_sat.vm_name,
    "--command-id RunShellScript --scripts",
    "'sudo cat /opt/hailbytes-sat/hailbytes-sat-initial-credentials.txt'",
    "--query 'value[0].message' -o tsv",
  ])
}
