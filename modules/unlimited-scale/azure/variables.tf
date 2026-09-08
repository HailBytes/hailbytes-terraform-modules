# ----- Required -----

variable "product" {
  type = string
  validation {
    condition     = contains(["asm", "sat"], var.product)
    error_message = "product must be one of: asm, sat."
  }
}

variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "vm_subnet_id" { type = string }
variable "db_delegated_subnet_id" { type = string }
variable "private_dns_zone_id" { type = string }
variable "allowed_cidrs" {
  description = "CIDR blocks permitted to reach the load balancer's admin frontend on port 443. On SAT, port 80 is the phishing/landing frontend and is governed by phish_allowed_cidrs instead."
  type        = list(string)
  validation {
    condition     = alltrue([for c in var.allowed_cidrs : can(cidrhost(c, 0))])
    error_message = "All allowed_cidrs entries must be valid CIDR blocks (e.g. \"10.0.0.0/8\")."
  }
}

variable "phish_allowed_cidrs" {
  description = "CIDRs permitted to reach the phishing/landing surface on the load balancer's port 80 (SAT only; ASM has no such surface). Leave null to inherit allowed_cidrs, which is the historical behaviour and keeps existing deployments planning clean. Set it whenever the simulation targets are not inside the admin allow-list -- with one shared list, locking the console to an office range also locks every target out of the landing pages, and the campaign sends and then records no interactions. \"0.0.0.0/0\" is the usual value for a live simulation."
  type        = list(string)
  default     = null

  validation {
    condition     = alltrue([for c in coalesce(var.phish_allowed_cidrs, []) : can(cidrhost(c, 0))])
    error_message = "All phish_allowed_cidrs entries must be valid CIDR blocks (e.g. \"0.0.0.0/0\")."
  }
}
variable "admin_username" { type = string }
variable "ssh_public_key" { type = string }

# ----- Key Vault network ACL -----

variable "key_vault_name" {
  description = "Override the Key Vault name. Leave null to derive it from name_prefix. Key Vault names are globally unique AND the vault is created with purge_protection_enabled = true and a 30-day soft-delete window, which disk encryption sets require and which cannot be force-purged. So destroying a stack and re-creating it under the same name inside 30 days FAILS, with no way out but waiting or renaming. If you are iterating on a PoC, set a unique name per iteration (e.g. hbsatkv0731a). Max 24 chars, alphanumerics and hyphens."
  type        = string
  default     = null

  validation {
    condition     = var.key_vault_name == null || can(regex("^[a-zA-Z][a-zA-Z0-9-]{2,23}$", var.key_vault_name))
    error_message = "key_vault_name must be 3-24 characters, start with a letter, and contain only alphanumerics and hyphens."
  }
}

variable "key_vault_network_default_action" {
  description = "Default action for the Key Vault network ACL. 'Allow' preserves the pre-network-ACL behavior (public endpoint open, RBAC-gated); set 'Deny' once you've added the operator IP to key_vault_ip_rules and the Microsoft.KeyVault service endpoint on vm_subnet_id. AzureServices bypass is always on so the VMSS managed identity can read secrets either way."
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

variable "associate_vm_subnet_nsg" {
  description = "Associate the module-managed NSG (allow-https-* rules built from allowed_cidrs) with vm_subnet_id. Set false if the subnet already has an NSG attached and your landing-zone tooling manages ingress; the NSG ID is still exported as vmss_nsg_id for you to reference."
  type        = bool
  default     = true
}

# ----- VMSS sizing -----

variable "vmss_min_count" {
  description = "Minimum number of VMSS instances."
  type        = number
  default     = 2
  validation {
    condition     = var.vmss_min_count >= 1
    error_message = "vmss_min_count must be at least 1."
  }
}

variable "vmss_max_count" {
  description = "Maximum number of VMSS instances the autoscaler can scale out to."
  type        = number
  default     = 20
  validation {
    condition     = var.vmss_max_count >= 1
    error_message = "vmss_max_count must be at least 1."
  }
}

variable "vmss_default_count" {
  description = "Starting instance count when the VMSS is created. Must be between vmss_min_count and vmss_max_count."
  type        = number
  default     = 3
  validation {
    condition     = var.vmss_default_count >= 1
    error_message = "vmss_default_count must be at least 1."
  }
}

variable "vm_size" {
  description = "Azure VM SKU for the HailBytes application node(s). Any Standard_* size with 2 or more vCPU is accepted; the default is a general-compute shape. THE ALLOWLIST WAS REMOVED ON PURPOSE. It was an enumerated list of nine Dsv5 rungs plus two B-series, and it blocked two real deployments: Standard_B4ms was rejected while it was the only family with quota in the target subscription, and every newer family (Dsv6, the as/ps AMD and ARM variants, the memory and compute-optimised lines) was rejected for having been released after the list was written. A hand-maintained list of SKUs goes stale faster than anyone updates it, and the failure mode is refusing a size the customer can actually get. QUOTA IS THE THING TO CHECK, NOT THE NAME. Every Dsv5 rung draws one pool, standardDSv5Family, which is frequently granted a limit of 0 in a subscription that has never asked for it -- so a Dsv5 size can be perfectly valid and still fail the apply. quickstart/preflight-azure.sh and the deployment bundles check the pool for whatever size is set, before anything is built. Confirm with: az vm list-usage --location <region> -o table. B-series is BURSTABLE: it banks CPU credits while idle and throttles to a fraction of a core once they are spent, which suits pilots and steady low load, not sustained campaign sending. Size from measured load rather than from a rung -- see hailbytes-sat/docs/VM_SCALING.md."
  type        = string
  default     = "Standard_D4s_v5"

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

variable "target_cpu_percent" {
  description = "Target average CPU utilization (percent, 1-100) for the VMSS autoscale policy."
  type        = number
  default     = 60
  validation {
    condition     = var.target_cpu_percent >= 1 && var.target_cpu_percent <= 100
    error_message = "target_cpu_percent must be between 1 and 100."
  }
}

# ----- DB sizing -----

variable "db_sku_name" {
  type    = string
  default = "GP_Standard_D4ds_v5"
}

variable "db_storage_mb" {
  description = "Storage size in MiB for the PostgreSQL Flexible Server. Minimum 32768 MiB (32 GiB); autoscaling grows in 32 GiB increments."
  type        = number
  default     = 262144
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
  description = "Days Azure Database for PostgreSQL retains automated backups. Azure Flexible Server enforces a minimum of 7 and a maximum of 35."
  type        = number
  default     = 30
  validation {
    condition     = var.db_backup_retention_days >= 7 && var.db_backup_retention_days <= 35
    error_message = "db_backup_retention_days must be between 7 and 35 (Azure Flexible Server constraint)."
  }
}

variable "db_replica_count" {
  description = "Number of Azure Database for PostgreSQL read replicas."
  type        = number
  default     = 2
  validation {
    condition     = var.db_replica_count >= 0 && var.db_replica_count <= 5
    error_message = "db_replica_count must be between 0 and 5."
  }
}

# ----- Misc -----

variable "environment" {
  type    = string
  default = "prod"
}

variable "name_prefix" {
  type    = string
  default = null
}

variable "alert_email" {
  type    = string
  default = null
}

variable "accept_marketplace_terms" {
  type    = bool
  default = true
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
  description = "Days the immutable blob policy keeps backup objects pinned (unlocked mode)."
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
  description = "Install a VMSS extension that bakes the pre-patch backup script. Customers fire it via `az vmss run-command invoke` or the Portal."
  type        = bool
  default     = true
}

variable "rolling_upgrade_max_batch_percent" {
  description = "VMSS rolling-upgrade batch size as a percentage of total instances. Lower = slower, safer; 20 keeps 80% of capacity online during an upgrade batch."
  type        = number
  default     = 20
}

variable "rolling_upgrade_max_unhealthy_percent" {
  description = "Maximum percentage of unhealthy VMSS instances permitted before the upgrade pauses. Lower = stricter; this is the Azure analogue of AWS instance-refresh auto-rollback."
  type        = number
  default     = 20
}

variable "enable_application_gateway" {
  description = "Front the LB topology with an Azure Application Gateway. Required for WAF parity with the AWS ALB+WAF story. The gateway fronts the admin console only: on SAT the phishing/landing surface stays on the Standard LB's port-80 frontend, because a WAF ruleset in front of a simulated credential-harvest page blocks the very interactions the product exists to record."
  type        = bool
  default     = false
}

variable "appgw_subnet_id" {
  description = "Subnet for the Application Gateway. Required when enable_application_gateway = true."
  type        = string
  default     = null
}

variable "appgw_tls_pfx_base64" {
  description = "Base64-encoded PFX for the App Gateway HTTPS listener. Required when enable_application_gateway = true."
  type        = string
  default     = null
  sensitive   = true
}

variable "appgw_tls_pfx_password" {
  description = "Password for the PFX bundle."
  type        = string
  default     = null
  sensitive   = true
}

variable "appgw_backend_host_header" {
  description = "Optional Host header App Gateway sends to the VMSS backend."
  type        = string
  default     = null
}

variable "waf_policy_id" {
  description = "Optional ID of an azurerm_web_application_firewall_policy to attach to the App Gateway."
  type        = string
  default     = null
}

variable "refresh_rollback_5xx_count_threshold" {
  description = "Backend 5xx response count over the alert window that trips the rolling-upgrade tripwire."
  type        = number
  default     = 50
}

variable "schema_version_endpoint_path" {
  description = "Path on the SAT/ASM API that returns the running schema version."
  type        = string
  default     = "/api/instance/schema-version"
}

variable "enable_post_patch_run_command" {
  description = "Install a VMSS extension named RunPostPatchVerify that runs the on-VM five-probe verifier, mirroring the AWS aws_ssm_document.post_patch_verify."
  type        = bool
  default     = true
}

# ----- Shared session store (Azure Cache for Redis) -----

variable "enable_managed_redis" {
  description = "Provision an Azure Cache for Redis (Standard or Premium SKU). Genuinely required on this tier, unlike ha-hot-hot: it is the only shared session store, because this module does not yet mint the shared session-keys secret that lets the stateless cookie store work across instances (hailbytes-sat#907). Set false only when supplying redis_endpoint_override -- turning it off outright makes every hop between instances an unrecoverable logout. See the comment on provision_managed_redis in main.tf."
  type        = bool
  default     = true
}

variable "redis_sku_name" {
  description = "Redis SKU. Standard delivers a primary/replica pair; Premium adds zone selection. Basic is single-node and breaks horizontal scaling (validated)."
  type        = string
  default     = "Standard"
  validation {
    condition     = contains(["Standard", "Premium"], var.redis_sku_name)
    error_message = "redis_sku_name must be one of: Standard, Premium. Basic is single-node and breaks horizontal scaling."
  }
}

variable "redis_family" {
  description = "Redis SKU family. 'C' = Standard/Basic, 'P' = Premium."
  type        = string
  default     = "C"
}

variable "redis_capacity" {
  description = "Redis capacity (size index). For SKU=Standard / family=C, valid values are 0-6. Scale alongside VMSS instance count: 1 (1GB) handles 3-5 instances; 3 (6GB) handles 10-20+."
  type        = number
  default     = 1
}

variable "redis_endpoint_override" {
  description = "Host of an existing customer-managed Redis endpoint. Pair with enable_managed_redis = false."
  type        = string
  default     = null
}

variable "redis_endpoint_override_port" {
  type    = number
  default = 6380
}

variable "redis_endpoint_override_tls" {
  type    = bool
  default = true
}

variable "db_secret_expiration_hours" {
  description = "Hours until the Key Vault DB-password secret expires. Default 8760 = one calendar year. Set on every apply via timeadd(timestamp(), ...) and then ignored on subsequent applies so a stale value doesn't show drift."
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

variable "health_check_path" {
  description = "Override the load-balancer health probe path. Leave null to use the product default: /api/health for SAT, /api/ready for ASM. Both are unauthenticated and return non-200 when the database is unreachable."
  type        = string
  default     = null
}

variable "admin_port" {
  description = "Port the admin UI listens on inside each instance. Leave null to derive it from `product`: 3333 for SAT (the image's config.json `listen_url`), 443 for ASM (its proxy container publishes 443). The load-balancer frontend stays on 443 regardless; this is the backend port."
  type        = number
  default     = null
}

variable "phish_port" {
  description = "Port the phishing/tracking server listens on inside each instance. SAT only -- it is the landing-page and interaction-tracking surface, which is the product. The Standard LB fronts it on port 80 and forwards to this port; ignored when `product` is \"asm\", which has no phishing surface. Leave null for the image default of 80."
  type        = number
  default     = null
}
