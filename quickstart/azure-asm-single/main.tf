# HailBytes ASM on Azure, single-VM tier: complete quickstart.
#
# The fallback when the HA tier is not available or not yet warranted. One VM,
# its own public IP, and PostgreSQL running ON the VM -- no Flexible Server, no
# load balancer, no Key Vault plumbing for a shared password.
#
# That is the whole trade. It is materially simpler and cheaper to stand up, and
# it has no redundancy: a reboot is an outage, and the VM's local database is the
# single copy of your campaign history. Take backups.
#
# Subscribe to the HailBytes ASM Azure Marketplace listing, run
# ../preflight-azure.sh single --product asm, set two variables in terraform.tfvars, then:
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

  features {
    key_vault {
      # This defaults to TRUE, and on true the provider will not create a vault
      # until it has checked whether a soft-deleted one already holds the name.
      # That check is a SUBSCRIPTION-scoped read:
      #
      #   Microsoft.KeyVault/locations/<region>/deletedVaults/<name>/read
      #
      # An operator whose access is scoped to a resource group rather than the
      # whole subscription cannot perform it -- a common shape in enterprise
      # tenants, where roles are granted per resource group. The provider does
      # not treat the refusal as "cannot tell": anything other than a clean 404
      # puts it on the recover path, so it asks Azure to RECOVER a vault that
      # never existed, and the apply dies with
      #
      #   400 SoftDeletedVaultDoesNotExist: A soft deleted vault with the given
      #   name does not exist.
      #
      # The message names soft delete and the real cause is RBAC scope, which
      # is why it is expensive to diagnose. Seen in a customer tenant on
      # 2026-09-07 on a freshly randomised name in a brand-new resource group,
      # so nothing was colliding.
      #
      # false skips the lookup and creates. If a soft-deleted vault genuinely
      # holds the name, Azure refuses with a message that says exactly that,
      # which is the honest failure. Nothing here wants to adopt a vault
      # somebody else deleted.
      recover_soft_deleted_key_vaults = false
    }
  }
}

variable "resource_group_name" {
  description = "Resource group to create. All quickstart resources live here. Leave null for rg-hailbytes-asm-single, or rg-<customer>-asm-<environment> when customer is set."
  type        = string
  default     = null
}

variable "customer" {
  description = "Short client name when you run one deployment per client (MSSP). Prefixes every resource and the resource group, and tags everything customer=<name> for per-client cost reports. Leave null for a single-organisation deployment. Set it on the FIRST apply only: changing it later renames, and so replaces, every resource."
  type        = string
  default     = null

  validation {
    condition     = var.customer == null || can(regex("^[a-z][a-z0-9-]{1,15}$", var.customer))
    error_message = "customer must be 2-16 characters: lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "accept_marketplace_terms" {
  description = "Accept the Marketplace image terms from Terraform. Leave null: true for a single deployment, false when customer is set. Terms are per SUBSCRIPTION, and Terraform treats them as a resource it owns -- a second deployment in the same subscription fails with 'already exists', and destroying ANY deployment cancels the terms for every other one. With customer set, accept them once instead: ../preflight-azure.sh single --product asm --accept-terms."
  type        = bool
  default     = null
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

locals {
  # Null customer reproduces the names this root has always used, so an
  # existing deployment plans clean.
  name_prefix         = var.customer == null ? "hailbytes-asm-${var.environment}" : "${var.customer}-asm-${var.environment}"
  resource_group_name = coalesce(var.resource_group_name, var.customer == null ? "rg-hailbytes-asm-single" : "rg-${var.customer}-asm-${var.environment}")
  accept_terms        = var.accept_marketplace_terms != null ? var.accept_marketplace_terms : var.customer == null
  tags                = var.customer == null ? {} : { customer = var.customer }
}

resource "azurerm_resource_group" "main" {
  name     = local.resource_group_name
  location = var.location
  tags     = local.tags
}

# The single-VM module needs exactly one subnet and brings no networking of its
# own. modules/network/azure emits more than this tier uses -- the delegated
# Postgres subnet and the privatelink DNS zone go unused here, because the
# database is local to the VM. Reusing the module anyway keeps one definition of
# the baseline network across both tiers rather than two that drift.
module "network" {
  source = "../../modules/network/azure"

  name_prefix         = local.name_prefix
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = local.tags

  # The workload module associates its own NSG, and Azure allows one NSG per
  # subnet, so the network module must not attach its baseline set. The flag
  # also stops those NSGs being created at all, which matters here because the
  # workload module's load-balancer NSG carries the same name.
  associate_subnet_nsgs = false
}

module "hailbytes_asm" {
  source = "../../modules/asm-azure-single"

  environment         = var.environment
  name_prefix         = local.name_prefix
  tags                = local.tags
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  subnet_id           = module.network.workload_subnet_id
  allowed_cidrs       = var.allowed_cidrs
  admin_username      = var.admin_username
  ssh_public_key      = var.ssh_public_key

  accept_marketplace_terms = local.accept_terms
}

output "resource_group_name" {
  description = "Where everything in this deployment lives. terraform destroy removes it; see docs/AZURE_MSSP_RUNBOOK.md, Step 9."
  value       = azurerm_resource_group.main.name
}

output "console_url" {
  description = "Admin UI. The certificate is self-signed on first boot, so expect a browser warning. (The module's own console_url output is the Azure portal page for the VM.)"
  value       = "https://${module.hailbytes_asm.public_ip_address}/"
}

output "public_ip_address" {
  value = module.hailbytes_asm.public_ip_address
}

output "vm_name" {
  description = "Use with 'az vm run-command invoke' to read the initial credentials file."
  value       = module.hailbytes_asm.vm_name
}

output "initial_credentials_command" {
  description = "Prints the initial admin password from inside the VM."
  value = join(" ", [
    "az vm run-command invoke -g", azurerm_resource_group.main.name,
    "-n", module.hailbytes_asm.vm_name,
    "--command-id RunShellScript --scripts",
    "'sudo grep DJANGO_SUPERUSER_PASSWORD /opt/hailbytes-asm/.env'",
    "--query 'value[0].message' -o tsv",
  ])
}
