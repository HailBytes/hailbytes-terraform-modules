# HailBytes SAT on Azure, unlimited-scale (autoscale) tier: complete quickstart.
#
# A VM scale set behind a load balancer, a Postgres Flexible Server, Azure
# Cache for Redis for shared sessions, and Key Vault. Like ../azure-ha, this
# root also builds the networking (vnet, workload subnet, delegated Postgres
# subnet, private DNS zone), so the only required inputs are allowed_cidrs and
# ssh_public_key:
#
#   terraform init && terraform apply
#
# Every running instance meters at $0.24/vCPU-hour, so vmss_max_count is the
# ceiling on the software bill as well as on capacity. See README.md.

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
  description = "Resource group to create. All quickstart resources live here. Leave null for rg-hailbytes-sat-autoscale, or rg-<customer>-sat-<environment> when customer is set."
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
  description = "Accept the Marketplace image terms from Terraform. Leave null: true for a single deployment, false when customer is set. Terms are per SUBSCRIPTION, and Terraform treats them as a resource it owns -- a second deployment in the same subscription fails with 'already exists', and destroying ANY deployment cancels the terms for every other one. With customer set, accept them once instead: ../preflight-azure.sh autoscale --accept-terms."
  type        = bool
  default     = null
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

variable "phish_allowed_cidrs" {
  description = "CIDRs allowed to reach the phishing/landing surface. Leave null and it inherits allowed_cidrs, which is correct only if every simulation target sits inside your admin range. For a live simulation set this (usually [\"0.0.0.0/0\"]), or the campaign sends and then records no interactions."
  type        = list(string)
  default     = null
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

variable "vm_size" {
  description = "Size of each scale-set instance. Standard_D2s_v3 matches the HA tier default and draws the standardDSv3Family quota pool; the module default (Standard_D4s_v5) draws standardDSv5Family, which subscriptions are often granted a limit of 0 in. Check with ../preflight-azure.sh autoscale --vm-size <size>."
  type        = string
  default     = "Standard_D2s_v3"
}

variable "vmss_min_count" {
  description = "Instances that always run. Each meters $0.24/vCPU-hour around the clock."
  type        = number
  default     = 2
}

variable "vmss_max_count" {
  description = "Ceiling the autoscaler may reach -- and so the ceiling on the hourly software bill and the vCPU quota the region must have."
  type        = number
  default     = 4
}

variable "db_replica_count" {
  description = "Postgres read replicas. Each is a full database server billed like the primary; the module default is 2. Start at 0 and add replicas when measured read load calls for them."
  type        = number
  default     = 0
}

variable "alert_email" {
  description = "Where scale and health alerts go. Null creates no email receiver."
  type        = string
  default     = null
}

locals {
  name_prefix         = var.customer == null ? "hailbytes-sat-${var.environment}" : "${var.customer}-sat-${var.environment}"
  resource_group_name = coalesce(var.resource_group_name, var.customer == null ? "rg-hailbytes-sat-autoscale" : "rg-${var.customer}-sat-${var.environment}")
  accept_terms        = var.accept_marketplace_terms != null ? var.accept_marketplace_terms : var.customer == null
  tags                = var.customer == null ? {} : { customer = var.customer }
}

resource "azurerm_resource_group" "main" {
  name     = local.resource_group_name
  location = var.location
  tags     = local.tags
}

module "network" {
  source = "../../modules/network/azure"

  name_prefix         = local.name_prefix
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = local.tags

  # The workload module associates its own NSG to the scale-set subnet, and
  # Azure allows one NSG per subnet.
  associate_subnet_nsgs = false
}

module "hailbytes_sat" {
  source = "../../modules/sat-azure-autoscale"

  environment            = var.environment
  name_prefix            = local.name_prefix
  tags                   = local.tags
  resource_group_name    = azurerm_resource_group.main.name
  location               = azurerm_resource_group.main.location
  vm_subnet_id           = module.network.workload_subnet_id
  db_delegated_subnet_id = module.network.db_delegated_subnet_id
  private_dns_zone_id    = module.network.private_dns_zone_id
  allowed_cidrs          = var.allowed_cidrs
  phish_allowed_cidrs    = var.phish_allowed_cidrs
  admin_username         = var.admin_username
  ssh_public_key         = var.ssh_public_key
  alert_email            = var.alert_email

  vm_size            = var.vm_size
  vmss_min_count     = var.vmss_min_count
  vmss_default_count = var.vmss_min_count
  vmss_max_count     = var.vmss_max_count
  db_replica_count   = var.db_replica_count

  accept_marketplace_terms = local.accept_terms

  # Globally unique, purge-protected, and reserved for 30 days after a destroy:
  # see the same setting in ../azure-ha/main.tf. Do NOT add this to a live
  # deployment that was applied without it -- it renames, and so destroys, the
  # vault.
  key_vault_name_random_suffix = true
}

output "resource_group_name" {
  description = "Where everything in this deployment lives. terraform destroy removes it; see docs/AZURE_MSSP_RUNBOOK.md, Step 9."
  value       = azurerm_resource_group.main.name
}

output "load_balancer_public_ip" {
  description = "Point your browser at https://<this IP>/ once apply completes."
  value       = module.hailbytes_sat.load_balancer_public_ip
}

output "vmss_name" {
  value = module.hailbytes_sat.vmss_name
}

output "postgres_primary_fqdn" {
  value = module.hailbytes_sat.postgres_primary_fqdn
}

output "key_vault_uri" {
  description = "The DB password is stored here under secret name 'hailbytes-db-password'."
  value       = module.hailbytes_sat.key_vault_uri
}

output "initial_credentials_command" {
  description = "Prints the first-boot admin password from each scale-set instance in turn. This tier has no shared admin-password secret yet, so instances can differ: log in with the first one that works."
  value = join(" ", [
    "for i in $(az vmss list-instances -g", azurerm_resource_group.main.name, "-n", module.hailbytes_sat.vmss_name, "--query '[].instanceId' -o tsv); do",
    "az vmss run-command invoke -g", azurerm_resource_group.main.name, "-n", module.hailbytes_sat.vmss_name, "--instance-id \"$i\"",
    "--command-id RunShellScript --scripts", "'sudo cat /opt/hailbytes-sat/hailbytes-sat-initial-credentials.txt'",
    "--query 'value[0].message' -o tsv; done",
  ])
}
