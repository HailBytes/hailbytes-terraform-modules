# ----- Required -----

variable "product" {
  type = string
  validation {
    condition     = contains(["asm", "sat"], var.product)
    error_message = "product must be one of: asm, sat."
  }
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "vm_subnet_id" {
  # NOTE FOR BRING-YOUR-OWN NETWORKS: this subnet is named in the Key Vault's
  # network ACL below, and Azure requires every subnet in a Key Vault ACL to
  # carry the Microsoft.KeyVault service endpoint -- regardless of
  # key_vault_network_default_action. Without it the vault fails to create with
  # 400 SubnetsHaveNoServiceEndpointsConfigured, and only at apply time, because
  # the validation is server-side and invisible to terraform plan.
  # modules/network/azure sets the endpoint for you; a hand-built subnet must:
  #   az network vnet subnet update -g <rg> --vnet-name <vnet> -n <subnet> \
  #     --service-endpoints Microsoft.KeyVault
  description = "Subnet for VMs. Must be in a vnet that also contains delegated subnet for Flexible Server Postgres."
  type        = string
}

variable "db_delegated_subnet_id" {
  description = "Subnet delegated to Microsoft.DBforPostgreSQL/flexibleServers (vnet-integrated Postgres). Required when db_mode = \"flexible_server\", which a precondition enforces. Leave null in \"vm\" and \"external\" modes: there is no Flexible Server to inject, so demanding it would force a delegated subnet nobody uses."
  type        = string
  default     = null
}

variable "private_dns_zone_id" {
  description = "Private DNS zone ID for postgres.database.azure.com (linked to the vnet). Required when db_mode = \"flexible_server\", which a precondition enforces. Leave null in \"vm\" and \"external\" modes."
  type        = string
  default     = null
}

variable "lb_subnet_id" {
  description = "Subnet for the internal Standard Load Balancer frontend. Often the same as vm_subnet_id."
  type        = string
}

variable "vm_subnet_is_lb_subnet" {
  description = <<-EOT
    Set true when vm_subnet_id and lb_subnet_id name the SAME subnet. Azure
    permits exactly one NSG per subnet, so in that topology the module skips its
    dedicated VM NSG and lets the lb NSG filter the shared subnet.

    This has to be an explicit input rather than a `vm_subnet_id != lb_subnet_id`
    comparison, because the module branches on it with count/for_each and those
    must resolve during plan. A caller that creates its subnets in the same apply
    -- network/azure feeding this module, which is the composition the READMEs
    document -- passes two values that are still "known after apply", and
    comparing them fails the whole plan with "Invalid count argument".

    Default false (the subnets differ) matches network/azure, every wrapper
    module, and the documented common case. Get it wrong and Azure rejects the
    second association on an already-filtered subnet at apply -- loud, not
    silent; the module's own check block flags the mismatch first.
  EOT
  type        = bool
  default     = false
}

variable "allowed_cidrs" {
  type = list(string)
  validation {
    condition     = alltrue([for c in var.allowed_cidrs : can(cidrhost(c, 0))])
    error_message = "All allowed_cidrs entries must be valid CIDR blocks (e.g. \"10.0.0.0/8\")."
  }
}

variable "phish_allowed_cidrs" {
  description = "CIDRs permitted to reach the phishing/landing surface (SAT only; ASM has no such surface). Leave null to inherit allowed_cidrs, which is the historical behaviour and keeps existing deployments planning clean. Set it whenever the simulation targets are not inside the admin allow-list -- with one shared list, locking the console to an office range also locks every target out of the landing pages, and the campaign sends and then records no interactions. \"0.0.0.0/0\" is the usual value for a live simulation and is accepted here without allow_internet_ingress: that flag guards the admin surface, and requiring it would re-couple the two lists this variable exists to separate."
  type        = list(string)
  default     = null

  validation {
    condition     = alltrue([for c in coalesce(var.phish_allowed_cidrs, []) : can(cidrhost(c, 0))])
    error_message = "All phish_allowed_cidrs entries must be valid CIDR blocks (e.g. \"0.0.0.0/0\")."
  }
}

variable "associate_vm_subnet_nsg" {
  description = "Associate the module-managed NSG (allow-https-* rules built from allowed_cidrs) with vm_subnet_id. Only applies when vm_subnet_is_lb_subnet = false (when both point at the same subnet, the lb NSG already covers it). Set false if the subnet already has an NSG attached and your landing-zone tooling manages ingress; the NSG ID is still exported as vm_nsg_id for you to reference."
  type        = bool
  default     = true
}

variable "admin_username" {
  type = string
}

variable "ssh_public_key" {
  type = string
}

# ----- Key Vault network ACL -----

variable "db_log_min_duration_ms" {
  description = "Log Postgres statements slower than this many milliseconds. Flexible Server's default is -1 (log nothing), which makes the PostgreSQLLogs diagnostic setting useless for triage. Matches the AWS parameter group's log_min_duration_statement. Set -1 to disable."
  type        = number
  default     = 1000
}

variable "enable_db_delete_lock" {
  description = "Place a CanNotDelete management lock on the Flexible Server. Azure has no deletion_protection argument the way RDS does; this is the equivalent. It blocks deletion by ANYONE including terraform destroy, so leave it off for PoCs (a locked server makes destroy fail partway and leave a half-destroyed stack) and turn it on for production. Disable it in a separate apply before a planned teardown."
  type        = bool
  default     = false
}

variable "enable_public_ip_delete_lock" {
  description = "Place a CanNotDelete management lock on the public IPs this module creates (the load-balancer frontend, and the Application Gateway frontend when enable_application_gateway = true). Azure has no undelete for a public IP -- a deleted address goes back to the pool and DNS has to be re-pointed at a new one, which is how a customer lost the address their hostname resolved to. Same trade-off as enable_db_delete_lock: the lock blocks deletion by ANYONE including terraform destroy, so leave it off for PoCs and turn it on for production, disabling it in a separate apply before a planned teardown. Never applied to a caller-supplied public_ip_id or appgw_public_ip_id -- those resources are yours."
  type        = bool
  default     = false
}

variable "key_vault_name" {
  description = "Override the Key Vault name. Leave null to derive it from name_prefix. Key Vault names are globally unique AND the vault is created with purge_protection_enabled = true and a 30-day soft-delete window, which disk encryption sets require and which cannot be force-purged. So destroying a stack and re-creating it under the same name inside 30 days FAILS, with no way out but waiting or renaming. If you are iterating on a PoC, set a unique name per iteration (e.g. hbsatkv0731a). Max 24 chars, alphanumerics and hyphens."
  type        = string
  default     = null

  validation {
    condition     = var.key_vault_name == null || can(regex("^[a-zA-Z][a-zA-Z0-9-]{2,23}$", var.key_vault_name))
    error_message = "key_vault_name must be 3-24 characters, start with a letter, and contain only alphanumerics and hyphens."
  }
}

variable "key_vault_name_random_suffix" {
  # OPT-IN, and it has to be: the name is what identifies the vault to Azure,
  # so switching this on for a deployment that already has one plans a DESTROY
  # and CREATE of the Key Vault -- taking the database password, the session
  # keys and the disk encryption key with it, and cascading into a replacement
  # of the disk encryption set and every disk it encrypts. Defaulting it to true
  # would do that silently on the next apply of every existing stack.
  #
  # New deployments should set it true. Existing ones should set key_vault_name
  # to the name they already hold, which pins it explicitly instead of leaving
  # it an accident of name_prefix.
  description = "Append a 6-character suffix, keyed on resource_group_name and location, to the derived Key Vault name. Set true on NEW deployments: Key Vault names are globally unique, so without it two stacks sharing a name_prefix (including any two callers on module defaults) collide, and destroying a stack or moving it to another resource group makes the next create fail with SoftDeletedVaultDoesNotExist for 30 days. Do NOT turn it on for an existing deployment -- it renames the vault, which destroys it; set key_vault_name to the current name instead. Ignored when key_vault_name is set."
  type        = bool
  default     = false
}

variable "key_vault_network_default_action" {
  description = "Default action for the Key Vault network ACL. 'Allow' preserves the pre-network-ACL behavior (public endpoint open, RBAC-gated); set 'Deny' once you've added the operator IP to key_vault_ip_rules and the Microsoft.KeyVault service endpoint on vm_subnet_id. AzureServices bypass is always on so the VMs' managed identities can read secrets either way."
  type        = string
  default     = "Allow"
  validation {
    condition     = contains(["Allow", "Deny"], var.key_vault_network_default_action)
    error_message = "key_vault_network_default_action must be one of: Allow, Deny."
  }
}

variable "key_vault_ip_rules" {
  description = "IPv4 addresses or CIDRs allowed to reach the Key Vault data plane (typically the operator IP running terraform apply, or your bastion's egress NAT). Required only when default_action = Deny and you don't have Private Link configured."
  type        = list(string)
  default     = []
}

# ----- Optional -----

variable "environment" {
  type    = string
  default = "prod"
}

variable "name_prefix" {
  type    = string
  default = null
}

variable "vm_names" {
  description = "Exact names for the two application VMs, in zone order -- element 0 lands in zone 1, element 1 in zone 2. Leave null to derive them as <name_prefix>-vm-1 and -vm-2. Set this when a host-naming standard governs VM names (e.g. [\"simsphishing-web-P-01\", \"simsphishing-web-P-02\"]); name_prefix still governs every other resource. Renaming an existing VM REPLACES it, so on a live deployment change one element at a time and apply with -target, or accept that both nodes are rebuilt at once -- which on a two-node HA pair is a full outage."
  type        = list(string)
  default     = null

  validation {
    condition     = var.vm_names == null || length(coalesce(var.vm_names, [])) == 2
    error_message = "vm_names must contain exactly two names -- the HA tier runs exactly two application VMs."
  }

  validation {
    condition = alltrue([
      for n in coalesce(var.vm_names, []) :
      can(regex("^[a-zA-Z0-9][a-zA-Z0-9._-]{0,62}[a-zA-Z0-9_]$", n))
    ])
    error_message = "Each vm_names entry must be 2-64 characters of letters, digits, hyphens, underscores or periods, and may not begin or end with a hyphen or period -- Azure rejects the rest."
  }

  validation {
    condition     = var.vm_names == null || length(distinct(coalesce(var.vm_names, []))) == length(coalesce(var.vm_names, []))
    error_message = "vm_names entries must be distinct."
  }
}

variable "db_vm_name" {
  description = "Exact name for the self-managed Postgres VM when db_mode = \"vm\". Leave null to derive it as <name_prefix>-db-vm. Ignored in flexible_server and external modes, where there is no VM to name. Renaming replaces the VM, which on this tier means restoring the database."
  type        = string
  default     = null

  validation {
    condition     = var.db_vm_name == null || can(regex("^[a-zA-Z0-9][a-zA-Z0-9._-]{0,62}[a-zA-Z0-9_]$", var.db_vm_name))
    error_message = "db_vm_name must be 2-64 characters of letters, digits, hyphens, underscores or periods, and may not begin or end with a hyphen or period."
  }
}

variable "vm_size" {
  description = "Azure VM SKU for the HailBytes application node(s). Any Standard_* size with 2 or more vCPU is accepted; the default is the smallest general-compute shape, on the D family generation most likely to already have quota. THE DEFAULT IS Standard_D2s_v3 FOR ONE REASON: it is the size a subscription that has never asked for anything is most likely to be able to actually deploy. It draws standardDSv3Family, which Azure grants a non-zero default to on most subscriptions; standardDSv5Family is commonly 0 on a subscription that has never requested it, which is what failed the 2026-09-06 apply twelve minutes in, after the network, Key Vault and database were already built. Two vCPU because that is the smallest shape this stack runs on, so it fits inside the smallest regional grant -- size UP from measured load, rather than starting large and discovering the quota ceiling during an apply. It is not burstable, which B-series is: B-series banks CPU credits while idle and throttles to a fraction of a core once they are spent, so it suits a pilot and steady low load but not sustained campaign sending. THE ALLOWLIST WAS REMOVED ON PURPOSE. It was an enumerated list of nine Dsv5 rungs plus two B-series, and it blocked two real deployments: Standard_B4ms was rejected while it was the only family with quota in the target subscription, and every newer family (Dsv6, the as/ps AMD and ARM variants, the memory and compute-optimised lines) was rejected for having been released after the list was written. A hand-maintained list of SKUs goes stale faster than anyone updates it, and the failure mode is refusing a size the customer can actually get. QUOTA IS THE THING TO CHECK, NOT THE NAME, and no validation can see it: it is per-family and per-region. quickstart/preflight-azure.sh and the deployment bundles check the pool for whatever size is set, before anything is built. Confirm with: az vm list-usage --location <region> -o table. Size from measured load rather than from a rung -- see hailbytes-sat/docs/VM_SCALING.md."
  type        = string
  default     = "Standard_D2s_v3"

  validation {
    # Shape, not membership. The vCPU count is the first run of digits after
    # the family letters, which holds across every current Azure family:
    # D4s_v5 -> 4, B4ms -> 4, E8ds_v5 -> 8, D16as_v5 -> 16, D2plds_v6 -> 2,
    # DC2s_v3 -> 2, DS2_v2 -> 2. Verified against those and against malformed
    # input before this replaced the enumerated list.
    #
    # Known imprecision, and it is the safe direction: a constrained-core SKU
    # such as Standard_E8-2s_v5 reports 8 here when only 2 vCPU are licensed.
    # That passes a >= 2 gate, which is correct -- it just is not a vCPU count
    # to bill from.
    # try(), not `can(...) && tonumber(regex(...))`. Terraform's && does not
    # short-circuit inside a validation condition: it evaluates both operands,
    # so a malformed size ("d4s_v5") made the second regex() throw
    #   Call to function "regex" failed: pattern did not match any part of the
    #   given string
    # instead of failing the condition. The operator then got a function-call
    # error naming variables.tf and a line number, rather than the error_message
    # written for exactly this case, and tests/vm_size_default.tftest.hcl's
    # a_malformed_size_is_refused failed because expect_failures cannot match a
    # thrown error. try() yields false on the throw, which is the intended
    # meaning: unparseable is not >= 2.
    condition = try(
      tonumber(regex("^Standard_[A-Za-z]{1,5}([0-9]+)", var.vm_size)[0]) >= 2,
      false
    )
    error_message = "vm_size must be an Azure SKU name of the form Standard_<family><vCPUs>[suffix][_vN] with 2 or more vCPU -- for example Standard_D4s_v5, Standard_B4ms, Standard_E8ds_v5, Standard_D16as_v5. Single-vCPU sizes (Standard_B1s, Standard_A1_v2) are refused: the application node runs the web tier, the worker and the phishing server together, and one core cannot carry them. Any family is allowed -- what is NOT checked here is whether this subscription has quota for it, because that is per-family and per-region and no validation can see it. Run quickstart/preflight-azure.sh, or az vm list-usage --location <region> -o table."
  }
}

variable "data_disk_size_gb" {
  type    = number
  default = 256
}

variable "enable_customer_managed_key" {
  description = "Encrypt VM disks, the PostgreSQL Flexible Server, and the backup Storage Account with a customer-managed RSA-4096 key in this module's Key Vault, instead of platform-managed keys. WARNING — DESTRUCTIVE ON AN EXISTING DEPLOYMENT: Azure allows Flexible Server CMK to be configured only at server creation, so turning this on for a server that already exists REPLACES the database. Set it on day one or migrate via point-in-time restore to a new server. It also cannot be turned back off once on. Cannot be combined with postgres_geo_redundant_backup_enabled (Azure requires a second key vault and identity in the paired region). Azure Cache for Redis is NOT covered: CMK there is an Enterprise-tier-only feature, and Enterprise retires 2027-03-31."
  type        = bool
  default     = false
}

variable "db_sku_name" {
  description = "Flexible Server SKU (e.g. GP_Standard_D2ds_v5)."
  type        = string
  default     = "GP_Standard_D2ds_v5"
}

variable "db_storage_mb" {
  type    = number
  default = 131072
  validation {
    condition     = var.db_storage_mb >= 32768
    error_message = "db_storage_mb must be at least 32768 MiB (Azure Flexible Server minimum of 32 GiB)."
  }
}

variable "db_version" {
  type    = string
  default = "16"
}

variable "db_backup_retention_days" {
  type    = number
  default = 14
  validation {
    condition     = var.db_backup_retention_days >= 7 && var.db_backup_retention_days <= 35
    error_message = "db_backup_retention_days must be between 7 and 35 (Azure Flexible Server constraint)."
  }
}

variable "db_high_availability_mode" {
  # "Disabled" omits the high_availability block entirely -- azurerm has no
  # off switch for it, so the block is dynamic on this value.
  #
  # Zone-redundant Postgres is an offer entitlement, not a regional capability.
  # A subscription without it fails ~15 minutes into the create with
  # MultiAzHaIsOfferRestricted, and nothing in a plan can predict it. Check
  # before deploying, per region:
  #
  #   az postgres flexible-server list-skus -l <region> \
  #     --query "[?name=='<sku>'].capabilities" -o json
  #
  # The application tier is still hot-hot across zones 1 and 2 with this
  # Disabled -- it is the DATABASE that loses its standby, so a zone loss
  # becomes a restore-from-backup rather than a failover. Acceptable for a
  # pilot, a decision to make deliberately for production.
  #
  # ADDING THE STANDBY LATER is the normal path when the entitlement arrives
  # after the deployment does, and it does NOT replace the server: switching
  # Disabled -> ZoneRedundant adds the high_availability block, which Azure
  # applies in place. `zone` is in the server's ignore_changes precisely so that
  # the pin this module sets while HA is off (beside vm[0], so the single-zone
  # database is not in a third zone nobody recorded) does not then fight the
  # platform for placement once it owns it. Expect a few minutes of failover
  # activity while Azure builds the standby; the plan itself shows an update,
  # not a replace. If it shows a replace, stop -- something else changed too.
  #
  # SameZone is NOT the cheap option. The standby is a full server in both
  # modes, so both bill 2x compute and 2x storage; SameZone trades the
  # zone-loss SLA for lower replication latency.
  description = "Postgres HA mode. ZoneRedundant gives a standby in another zone (requires the subscription to be entitled to it - see MultiAzHaIsOfferRestricted); SameZone puts the standby in the same zone, which costs the same and trades the zone-loss SLA for lower replication latency; Disabled omits HA entirely, which is the only option on a subscription without the zone-redundant offer. Switching Disabled -> ZoneRedundant later updates the server in place rather than replacing it."
  type        = string
  default     = "ZoneRedundant"

  validation {
    condition     = contains(["ZoneRedundant", "SameZone", "Disabled"], var.db_high_availability_mode)
    error_message = "db_high_availability_mode must be ZoneRedundant, SameZone or Disabled."
  }
}

variable "accept_marketplace_terms" {
  type    = bool
  default = true
}

# ----- TEST-ONLY image override -----
#
# DELIBERATE, REVIEWED EXCEPTION to the "no modules that deploy from
# custom-built AMIs/VHDs" rule in CLAUDE.md. Approved for one purpose: the
# image-side fixes for hailbytes-sat#905/#906/#907/#908 cannot be observed on a
# real two-node stack until a VM can boot an image that CONTAINS them, and the
# published marketplace image by definition does not yet.
#
# Constraints that keep this from becoming a billing bypass:
#   * null by default, so every default deployment is unchanged and marketplace-
#     billed. Nothing about the shipped path moves.
#   * Accepts only an Azure Compute Gallery image version id, validated below --
#     not an arbitrary VHD or a managed image outside a gallery.
#   * When set, the `plan` block is dropped, so the deployment is NOT
#     marketplace-metered and is therefore unfit to sell from. That is the
#     point: it is only usable for testing images we built ourselves.
#
# Do NOT set this in a customer deployment or in any published example.
variable "source_image_id" {
  description = "TEST ONLY. Azure Compute Gallery image version id to boot instead of the marketplace image. Leave null for all real deployments -- setting it drops the marketplace `plan` block, so the VMs are not marketplace-metered. Exists so image-side fixes can be validated before publication."
  type        = string
  default     = null

  validation {
    condition = var.source_image_id == null || can(regex(
      "^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.Compute/galleries/[^/]+/images/[^/]+/versions/[^/]+$",
      var.source_image_id
    ))
    error_message = "source_image_id must be a full Azure Compute Gallery image VERSION id (/subscriptions/../resourceGroups/../providers/Microsoft.Compute/galleries/../images/../versions/..). Arbitrary managed-image or VHD ids are refused on purpose."
  }
}

variable "marketplace_sku_override" {
  description = "Override the marketplace SKU (plan name) if your subscription points at a non-default plan."
  type        = string
  default     = null
}

variable "marketplace_image_version" {
  description = "Marketplace image version. Pin to an explicit version for reproducible production deploys."
  type        = string
  default     = "latest"
}

# ----- Patching and migration safety -----

variable "db_mode" {
  description = "Database backend. 'flexible_server' (default) provisions Azure Database for PostgreSQL Flexible Server — recommended for production, and the only mode with zone-redundant failover and point-in-time restore. 'vm' provisions a third Linux VM with self-managed Postgres 16 for customers that must keep the data plane on a VM. 'external' connects to a Postgres server the customer already operates: the module provisions no database at all, and the customer owns availability, backups and patching for it."
  type        = string
  default     = "flexible_server"
  validation {
    condition     = contains(["flexible_server", "vm", "external"], var.db_mode)
    error_message = "db_mode must be one of: flexible_server, vm, external."
  }
}

variable "db_vm_size" {
  description = "VM SKU for the self-managed Postgres VM (db_mode = vm)."
  type        = string
  default     = "Standard_D2s_v5"
}

variable "db_vm_data_disk_size_gb" {
  description = "Size of the Premium_LRS disk backing /var/lib/postgresql on the self-managed Postgres VM."
  type        = number
  default     = 256
}

variable "create_backup_storage_account" {
  # Default flipped to false, same root cause as network/azure's
  # enable_flow_logs: this account is created with shared_access_key_enabled =
  # false and public_network_access_enabled = false, and the azurerm provider
  # reads its queue service properties over the storage DATA PLANE. An apply run
  # from outside the vnet therefore fails with 403
  # KeyBasedAuthenticationNotPermitted, on refresh as well as create.
  #
  # account_kind is now BlobStorage, which should remove that call entirely --
  # the provider only manages queue properties for kinds that support queues.
  # That is the intended fix, but it has NOT yet been confirmed against a real
  # apply, so this default stays false until it has been.
  description = "Provision a Storage Account + immutable container for pre-patch /api/instance/export bundles."
  type        = bool
  default     = false
}

variable "backup_storage_account_name" {
  description = "Name of an existing Storage Account to use. If null and create_backup_storage_account is true, the module names one."
  type        = string
  default     = null
}

variable "backup_storage_replication" {
  description = "Replication type for the backup storage account. GRS (geo-redundant, cross-region) is the default and the strongest option this account can take: account_kind is BlobStorage, which supports LRS, GRS and RAGRS only -- the zone-redundant tiers (ZRS, GZRS, RAGZRS) are a StorageV2/BlockBlobStorage feature and Azure rejects them here at apply time. For backup bundles cross-region beats zone-local anyway: GRS survives the loss of the whole region, ZRS only the loss of a zone."
  type        = string
  default     = "GRS"

  validation {
    condition     = contains(["LRS", "GRS", "RAGRS"], var.backup_storage_replication)
    error_message = "backup_storage_replication must be LRS, GRS or RAGRS. The backup account is account_kind = \"BlobStorage\" (blob-only, chosen so the azurerm provider makes no queue-service call over a data plane this account closes), and that kind does not offer the zone-redundant tiers -- Azure fails the apply with \"`account_replication_type` of `ZRS` isn't supported for Blob Storage accounts\" partway through, after other resources are already built."
  }
}

variable "backup_immutability_days" {
  description = "Days the immutable blob policy keeps backup objects pinned (unlocked mode so customers can extend later)."
  type        = number
  default     = 30
}

variable "backup_blob_soft_delete_days" {
  description = "Soft-delete window for blobs and containers."
  type        = number
  default     = 30
}

variable "backup_blob_noncurrent_expiration_days" {
  description = "Expire noncurrent blob versions after this many days."
  type        = number
  default     = 365
}

variable "enable_pre_patch_run_command" {
  # DEFAULT FLIPPED TO false, and the reason is the create-time execution below
  # rather than anything wrong with the backup itself.
  #
  # azurerm_virtual_machine_run_command EXECUTES on create. It does not merely
  # register the script the way the aws_ssm_document it mirrors does. So the
  # FIRST apply runs a pre-patch backup against a brand-new, empty instance --
  # a backup with nothing in it, taken at the one moment it cannot be useful --
  # and any non-zero exit from it fails the whole apply. On a customer's run
  # that is exactly what happened: the script called an Azure CLI the
  # marketplace image does not ship, exited 127 AFTER writing a valid bundle,
  # and took the apply red at resource 55 of 59 with every piece of
  # infrastructure already built and working.
  #
  # The script is fail-soft about the missing CLI now, but the shape of the
  # hazard is unchanged: a Portal convenience document is wired so that its
  # dry run decides whether a 45-minute deployment succeeds. Off by default
  # removes that from the first apply and costs nothing else.
  #
  # Turning it ON in a LATER apply installs the document and runs it once
  # against a live instance -- which is a real backup, unlike the one on create.
  # That is the recommended way to have it.
  description = "Install an Azure Run Command named RunPrePatchBackup on the first VM, for customers to fire from the Portal before a patch. Default false. NOTE: azurerm_virtual_machine_run_command EXECUTES on create -- so enabling it on a FIRST apply runs a backup against an empty instance and lets that run decide whether the deployment succeeds. Enable it in a later apply instead, where the one execution it triggers happens against a live instance and is worth having."
  type        = bool
  default     = false
}

variable "enable_post_patch_run_command" {
  description = "Install an Azure Run Command named RunPostPatchVerify on each VM, mirroring aws_ssm_document.post_patch_verify in the SAT/ASM aws-ha modules. Customers fire it from the Portal after a Run Command-driven image swap. Same caveat as enable_pre_patch_run_command: it EXECUTES on create, so it also serves as a first-apply health gate -- which is useful, but means a genuine verify failure correctly fails the apply."
  type        = bool
  default     = true
}

# ----- Shared session store (Azure Cache for Redis) -----

# Whether to provision the cache at all. Three facts decide it, and the third
# is the one that gets missed:
#
#  1. It is not required. Shared session hash/encryption keys make the default
#     cookie store work across both nodes (hailbytes-sat#907); the session
#     payload is a handful of scalars and travels in the cookie.
#  2. On the default Standard SKU it is NOT zone-redundant. Both nodes of the
#     primary/replica pair sit in one zone -- Azure offers zone redundancy for
#     this service on Premium and above only (+~$304/mo). So at the default it
#     is a single-zone dependency inside a zone-redundant topology.
#  3. When it is unreachable the application does not degrade evenly. SAT picks
#     its session store once, at boot (middleware.InitSessionStore), so a cache
#     that dies later stays selected: reads treat "Redis down" as "no session"
#     and log everyone out, and writes return the error, so nobody can log back
#     IN until it returns. A zonal outage that takes the cache therefore takes
#     the admin console -- the failure this tier exists to survive.
#
# Turning it off removes a single-zone dependency from the critical path and
# saves ~$101/mo. Leaving it on is defensible if session payloads may outgrow
# the 4 KB cookie limit, or with redis_sku_name = "Premium" and the cost
# accepted. The default is unchanged pending a product decision -- it is not
# the obvious choice it looks like.
variable "enable_managed_redis" {
  description = "Provision an Azure Cache for Redis. NOT required for HA -- shared session keys make the default cookie store work across nodes (hailbytes-sat#907), so this is an optimisation, and at the default Standard SKU it is a single-zone one. Read the comment above before leaving it on. Defaults true, which means a default apply needs the Microsoft.Cache provider registered; set false to skip both."
  type        = bool
  default     = false
}

variable "redis_sku_name" {
  description = "Redis SKU. Standard delivers a primary/replica pair across two zones; Premium adds persistence and explicit zone selection. Basic is single-node and NOT a valid HA option (validated)."
  type        = string
  default     = "Standard"
  validation {
    condition     = contains(["Standard", "Premium"], var.redis_sku_name)
    error_message = "redis_sku_name must be one of: Standard, Premium. Basic is single-node and breaks HA."
  }
}

variable "redis_family" {
  description = "Redis SKU family. 'C' = Standard/Basic, 'P' = Premium. Must match redis_sku_name."
  type        = string
  default     = "C"
  validation {
    condition     = contains(["C", "P"], var.redis_family)
    error_message = "redis_family must be one of: C, P."
  }
}

variable "redis_capacity" {
  description = "Redis capacity (size index). For SKU=Standard / family=C, valid values are 0 (250MB) through 6 (53GB). cache.t4g.small-equivalent is 1 (1GB)."
  type        = number
  default     = 1
}

variable "redis_endpoint_override" {
  description = "Host of an existing customer-managed Redis endpoint (Azure Cache, self-managed Redis Sentinel, etc.). Pair with enable_managed_redis = false."
  type        = string
  default     = null
}

variable "redis_endpoint_override_port" {
  description = "Port on the customer-managed Redis endpoint. 6380 (TLS) is the Azure default. Ignored unless redis_endpoint_override is set."
  type        = number
  default     = 6380
  validation {
    condition     = var.redis_endpoint_override_port >= 1 && var.redis_endpoint_override_port <= 65535
    error_message = "redis_endpoint_override_port must be between 1 and 65535."
  }
}

variable "redis_endpoint_override_tls" {
  description = "Whether the customer-managed Redis endpoint requires in-transit TLS. Ignored unless redis_endpoint_override is set."
  type        = bool
  default     = true
}

variable "enable_application_gateway" {
  description = "Front the LB topology with an Azure Application Gateway. Required if you want WAF parity with the AWS ALB+WAF story; the existing Standard LB is L4-only and cannot host WAF rules."
  type        = bool
  default     = false
}

variable "public_ip_id" {
  # Asked for by a customer who runs their own authoritative DNS and wanted the
  # A record in place before the deployment, rather than reading the address off
  # a completed apply. Without this the address does not exist until the load
  # balancer is created, which forces DNS to be a post-deploy step.
  #
  # The module-created IP is already allocation_method = "Static", so it is
  # stable across applies. This is about existing EARLIER, not about being more
  # stable.
  #
  # Bring your own and this module will not create or destroy it. That is the
  # point: an IP whose lifecycle you own survives a terraform destroy of the
  # deployment, so the DNS record stays valid across a rebuild.
  description = "Resource ID of an existing Static, Standard-SKU public IP to use for the load balancer frontend. Leave null and the module creates one. Bring your own to reserve the address and register DNS before the first apply; its lifecycle stays yours, so it survives a destroy."
  type        = string
  default     = null
}

variable "lb_frontend_public" {
  # The App Gateway does NOT sit in front of this load balancer: its backend
  # pool points at the VM private IPs, so the two are PARALLEL public entry
  # points to the same admin_port. An operator who enables the gateway to attach
  # a WAF therefore still has a second, un-WAF-ed public route to that port.
  # var.allowed_cidrs bounds both, so it was never an open internet surface --
  # but there was no way to close it without also giving up the gateway.
  #
  # false makes the load-balancer frontend internal (a private address in
  # lb_subnet_id), leaving the gateway as the only public route.
  #
  # ASM ONLY. SAT's phishing server shares this one frontend (80 -> phish_port),
  # and the gateway has a single listener on 443 routing to the admin backend --
  # no port-80 path at all. So on SAT an internal frontend does not just close
  # the admin bypass, it takes the phishing landing pages off the internet.
  # azurerm_lb.main refuses the combination at plan time rather than shipping a
  # deployment whose core function is unreachable.
  #
  # WATCH OUT FOR EGRESS. This module defines no outbound rule, so backend VMs
  # get implicit outbound SNAT from the load balancer's PUBLIC frontend. Make it
  # internal and that path is gone. network/azure attaches a NAT Gateway to the
  # workload subnet by default (enable_nat_gateway = true) and a NAT Gateway
  # takes precedence over LB SNAT anyway, so the default composition is
  # unaffected. But if you bring your own network with no NAT Gateway and no
  # other egress, the nodes lose outbound internet.
  description = "Whether the load balancer frontend gets a public IP. Default true. ASM only: on SAT the phishing server shares this frontend and the App Gateway has no port-80 listener to replace it, so the combination is refused at plan time. Set false (ASM, and only with enable_application_gateway = true) to make the frontend internal, so the App Gateway is the single public route to the admin port and no traffic can bypass a WAF policy attached to it. Requires egress independent of the load balancer -- a NAT Gateway, as network/azure provisions by default."
  type        = bool
  default     = true
}

variable "appgw_public_ip_id" {
  # var.public_ip_id fronts the LOAD BALANCER. When the App Gateway is enabled
  # the gateway is the front door and the LB becomes an internal hop, so a
  # customer who brought their own IP found the console answering on a
  # module-created address instead -- and DNS they had registered in advance
  # pointed at the wrong place. This is the gateway's equivalent.
  #
  # Same contract as public_ip_id: Static, Standard SKU, lifecycle stays the
  # caller's, so the address survives a terraform destroy and the DNS record
  # stays valid across a rebuild.
  description = "Resource ID of an existing Static, Standard-SKU public IP for the Application Gateway frontend. Leave null and the module creates one. Ignored unless enable_application_gateway = true. Bring your own to register DNS before the first apply; its lifecycle stays yours."
  type        = string
  default     = null
}

variable "key_vault_reader_principal_ids" {
  # The apply identity gets Key Vault Secrets Officer (see kv_secret_writer in
  # main.tf). When the deployment runs as a service principal rather than as a
  # person, that means NO HUMAN can read or rotate the database password or the
  # shared session keys without authenticating as the service principal.
  #
  # That is a defensible posture for deployment, and a bad one for an incident
  # at 3am. Grant your operators here at deploy time instead of discovering the
  # gap when you need the credential.
  #
  # Object IDs, not names: users, groups or service principals. A group is the
  # better choice, since membership changes without a terraform apply.
  description = "Additional Entra object IDs (users, groups or service principals) to grant Key Vault Secrets User on the deployment's vault. Use when the apply runs as a service principal, so that a human can still read and rotate the database password and session keys."
  type        = list(string)
  default     = []
}

variable "appgw_subnet_id" {
  # /24 is Microsoft's RECOMMENDATION, not a requirement. Their words: "Although
  # a /24 subnet isn't required per Application Gateway v2 SKU deployment, we
  # highly recommend it. A /24 subnet ensures that Application Gateway v2 has
  # sufficient space for autoscaling expansion and maintenance upgrades."
  #
  # The actual requirement is arithmetic: subnet size, minus 5 addresses Azure
  # reserves in every subnet, minus the gateway's MAX instance count, minus one
  # more if it has a private frontend IP. This module sets max_capacity = 10 and
  # uses a public frontend only, so it needs 15 addresses:
  #
  #   /28  16 - 5 = 11 usable, 10 for instances ->  1 spare. Works, no headroom.
  #   /27  32 - 5 = 27 usable, 10 for instances -> 17 spare. Comfortable.
  #   /24 256 - 5 = 251 usable                  -> Microsoft's recommendation.
  #
  # So /27 is the practical floor for THIS module's capacity, and a customer who
  # cannot spare a /24 is not blocked. Raise max_capacity and the floor rises
  # with it. https://learn.microsoft.com/en-us/azure/application-gateway/configuration-infrastructure
  description = "Dedicated subnet for the Application Gateway, in the same vnet as the VMs. Required when enable_application_gateway = true. /24 is Microsoft's recommendation; /27 is the practical floor at this module's max_capacity of 10. No other resource may share it."
  type        = string
  default     = null
}

variable "appgw_tls_pfx_base64" {
  description = "Base64-encoded PFX bundle for the App Gateway HTTPS listener. Required when enable_application_gateway = true."
  type        = string
  default     = null
  sensitive   = true
}

variable "appgw_tls_pfx_password" {
  description = "Password for the PFX bundle. Required when enable_application_gateway = true if the PFX is encrypted."
  type        = string
  default     = null
  sensitive   = true
}

variable "appgw_backend_host_header" {
  description = "Host header App Gateway sends to the backend pool, and the name it validates the backend certificate's CN against. **Required when appgw_backend_protocol = \"Https\"** — App Gateway v2 checks that this matches the CN the backend presents. The marketplace image's first-boot self-signed certificate uses CN \"hailbytes-sat-admin\", so that is the value to set unless you have replaced the certificate on the VMs."
  type        = string
  default     = null
}

variable "appgw_backend_protocol" {
  description = "Protocol for the App Gateway -> VM hop. \"Http\" terminates TLS at the gateway and uses the private VNet hop in clear — simplest, and the hop never leaves the customer's vnet. \"Https\" gives end-to-end encryption but requires appgw_backend_root_cert_pem and appgw_backend_host_header, because App Gateway v2 validates the backend certificate against an uploaded trusted root and matches its CN."
  type        = string
  default     = "Http"
  validation {
    condition     = contains(["Http", "Https"], var.appgw_backend_protocol)
    error_message = "appgw_backend_protocol must be one of: Http, Https."
  }
}

variable "appgw_backend_port" {
  description = "Port App Gateway connects to on the VMs. 443 pairs with appgw_backend_protocol = \"Https\"; 80 pairs with \"Http\"."
  type        = number
  default     = 80
}

variable "appgw_backend_root_cert_pem" {
  description = "PEM-encoded root certificate of the backend server certificate, uploaded to App Gateway as a trusted root. Required when appgw_backend_protocol = \"Https\": Microsoft's end-to-end TLS documentation states that a self-signed or unknown-CA backend certificate will only be trusted if its root is in the backend settings' trusted-root list, otherwise the gateway marks the pool unhealthy and serves 502. For the marketplace image's self-signed certificate, the certificate is its own root — read it off a VM at /opt/hailbytes-sat/hailbytes-sat-admin.crt."
  type        = string
  default     = null
}

variable "waf_policy_id" {
  description = "Optional ID of an azurerm_web_application_firewall_policy to attach to the App Gateway. HailBytes does not bundle a managed ruleset; most enterprises bring their own."
  type        = string
  default     = null
}

variable "alert_email" {
  description = "Email subscribed to the patching tripwire action group. Pass null to skip."
  type        = string
  default     = null
}

variable "refresh_rollback_5xx_count_threshold" {
  description = "Backend 5xx response count over 5 minutes that trips the patching alarm on the Application Gateway. Tune for site traffic; the Azure metric is a count, not a rate."
  type        = number
  default     = 10
}

variable "schema_version_endpoint_path" {
  description = "Path on the SAT/ASM API that returns the running schema version."
  type        = string
  default     = "/api/instance/schema-version"
}

variable "db_secret_expiration_hours" {
  description = "Hours until the Key Vault DB-password secret expires. Set on every apply via `timeadd(timestamp(), ...)` and then ignored on subsequent applies so a stale value doesn't show drift. Default 8760 = one calendar year — long enough that ops don't need to rotate weekly, short enough that the secret never lives unrotated past a year without operator attention."
  type        = number
  default     = 8760
}


variable "postgres_geo_redundant_backup_enabled" {
  description = "Enable geo-redundant backup on the Postgres Flexible Server. Defaults to false; adds cross-region replication of backups for DR scenarios. CKV_AZURE_136."
  type        = bool
  default     = false
}

variable "tags" {
  type    = map(string)
  default = {}
}

# ----- Redis Private Link -----

variable "redis_private_dns_zone_id" {
  description = "Resource ID of an existing 'privatelink.redis.cache.windows.net' private DNS zone, linked to the vnet holding vm_subnet_id. Leave null and the module creates and links one. Supply a shared zone when several stacks live in the same resource group — private DNS zone names are unique per resource group, so two stacks that each create their own will collide."
  type        = string
  default     = null
}

variable "redis_private_endpoint_subnet_id" {
  description = "Subnet for the Azure Cache for Redis private endpoint. Defaults to vm_subnet_id, which is correct for the standard topology; override only if your landing zone requires private endpoints in a dedicated subnet."
  type        = string
  default     = null
}

variable "admin_port" {
  description = "Port the HailBytes admin server listens on. The load balancer's 443 frontend forwards here, the health probe targets it, and the post-patch verifier probes it over localhost. Leave null to derive it from `product`: 3333 for SAT, 443 for ASM."
  type        = number
  default     = null
}

variable "phish_port" {
  description = "Port the HailBytes phishing/tracking server listens on. The load balancer's 80 frontend forwards here. On SAT this is the landing-page and interaction-tracking surface, which is the product; on ASM it is unused. Leave null for the image default of 80."
  type        = number
  default     = null
}

# ----- Customer-managed Postgres (db_mode = "external") -----
#
# Mirrors the redis_endpoint_override escape hatch. A customer who already runs
# Postgres at scale can point the stack at it and pay Azure nothing for a
# database. The password lands in this module's Key Vault under the same secret
# name the other two modes use, so the marketplace image bootstraps identically.

variable "external_db_host" {
  description = "Hostname or private IP of a customer-operated PostgreSQL server. Required when db_mode = \"external\", ignored otherwise. Must be resolvable and reachable from vm_subnet_id."
  type        = string
  default     = null
}

variable "external_db_port" {
  description = "Port of the customer-operated PostgreSQL server."
  type        = number
  default     = 5432
  validation {
    condition     = var.external_db_port >= 1 && var.external_db_port <= 65535
    error_message = "external_db_port must be between 1 and 65535."
  }
}

variable "external_db_name" {
  description = "Database name on the customer-operated server. It must already exist; the module does not create it."
  type        = string
  default     = "hailbytes"
}

variable "external_db_username" {
  description = "Role the application connects as. It needs full DDL rights on external_db_name — the binary runs goose migrations at boot."
  type        = string
  default     = "hailbytes"
}

variable "external_db_password" {
  description = "Password for external_db_username. Required when db_mode = \"external\". Written to this module's Key Vault as 'hailbytes-db-password'; supply it through a tfvars file or TF_VAR_ environment variable, never a literal in version control."
  type        = string
  default     = null
  sensitive   = true
}

variable "external_db_sslmode" {
  description = "libpq sslmode for the connection to the customer-operated server. 'require' is the minimum this module accepts; 'verify-full' is recommended when the server presents a certificate chained to a CA the VMs trust."
  type        = string
  default     = "require"
  validation {
    condition     = contains(["require", "verify-ca", "verify-full"], var.external_db_sslmode)
    error_message = "external_db_sslmode must be one of: require, verify-ca, verify-full. Unencrypted modes (disable, allow, prefer) are not accepted."
  }
}

# ----- Observability and management access -----

variable "enable_diagnostics" {
  description = "Send load-balancer, database, cache and (when enabled) Application Gateway diagnostics to a Log Analytics workspace. Closes the gap between SECURITY-DEFAULTS.md's logging claims and what the Azure modules actually did. Note the Standard Load Balancer is L4 and has no request-level access log — the App Gateway's ApplicationGatewayAccessLog is the closest analogue of AWS ALB access logs. Log Analytics ingestion is billed per GB by Azure."
  type        = bool
  default     = true
}

variable "log_analytics_workspace_id" {
  description = "Resource ID of an existing Log Analytics workspace to send diagnostics to. Leave null and the module creates one. Supply your landing zone's central workspace if you have one — most enterprises do, and a per-deployment workspace fragments their queries."
  type        = string
  default     = null
}

variable "diagnostics_retention_days" {
  description = "Retention for the module-created Log Analytics workspace. Ignored when log_analytics_workspace_id is supplied."
  type        = number
  default     = 30
  validation {
    condition     = var.diagnostics_retention_days >= 30 && var.diagnostics_retention_days <= 730
    error_message = "diagnostics_retention_days must be between 30 and 730 (Log Analytics constraint)."
  }
}

variable "enable_management_access" {
  description = "Install the AADSSHLoginForLinux extension on each app VM, giving Entra-authenticated and RBAC-gated SSH via `az ssh vm` with no public IP. This is the Azure counterpart of the AWS module's enable_management_access (SSM Session Manager). Operators still need the 'Virtual Machine Administrator Login' or 'User Login' role assigned to them — the extension provides the mechanism, not the grant."
  type        = bool
  default     = false
}

variable "health_check_path" {
  description = "Override the load-balancer health probe path. Leave null to use the product default: /api/health for SAT, /api/ready for ASM. Both are unauthenticated and return non-200 when the database is unreachable."
  type        = string
  default     = null
}
