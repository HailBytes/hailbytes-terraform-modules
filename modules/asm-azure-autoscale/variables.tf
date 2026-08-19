# Variables for ASM on Azure (autoscale)
# Mirrors modules/unlimited-scale/azure/variables.tf (without `product`,
# which is hardcoded by this wrapper).

variable "resource_group_name" { type = string }

variable "location" { type = string }

variable "vm_subnet_id" { type = string }

variable "db_delegated_subnet_id" { type = string }

variable "private_dns_zone_id" { type = string }

variable "allowed_cidrs" { type = list(string) }

variable "admin_username" { type = string }

variable "ssh_public_key" { type = string }

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

variable "vmss_min_count" {
  description = "Minimum number of VMSS instances."
  type        = number
  default     = 2
}

variable "vmss_max_count" {
  description = "Maximum number of VMSS instances the autoscaler can scale out to."
  type        = number
  default     = 20
}

variable "vmss_default_count" {
  description = "Starting instance count when the VMSS is created. Must be between vmss_min_count and vmss_max_count."
  type        = number
  default     = 3
}

variable "vm_size" {
  description = "Azure VM SKU for the HailBytes application node(s). Constrained to the portable Dsv5 ladder; see the validation message. Defaults to the 8-vCore training floor."
  type        = string
  default     = "Standard_D8s_v5"

  validation {
    # The portable ladder. Every entry is a stock Dsv5 general-purpose shape at
    # the same 4 GB-per-vCore ratio as the AWS m6i equivalent, so a deployment
    # can move between clouds without changing tier. B2s is the pilot exception.
    condition = contains([
      "Standard_B2s",     # 2 vCPU  - pilot, phishing simulation only
      "Standard_D2s_v5",  # 2 vCPU  - phishing simulation only
      "Standard_D4s_v5",  # 4 vCPU  - phishing simulation only
      "Standard_D8s_v5",  # 8 vCPU  - training floor and purchasable entry rung
      "Standard_D16s_v5", # 16 vCPU
      "Standard_D32s_v5", # 32 vCPU
      "Standard_D48s_v5", # 48 vCPU
      "Standard_D64s_v5", # 64 vCPU
    ], var.vm_size)
    error_message = "vm_size must be a portable HailBytes rung: Standard_B2s or Standard_D2s_v5 (2 vCPU), Standard_D4s_v5 (4), Standard_D8s_v5 (8), Standard_D16s_v5 (16), Standard_D32s_v5 (32), Standard_D48s_v5 (48), Standard_D64s_v5 (64). Azure Dsv5 has NO general-purpose size between 16 and 32 vCPU -- there is no Standard_D24s_v5 -- so a 24-vCore deployment cannot be delivered as one VM or as a symmetric pair; quote 16 or 32. The 2 and 4 vCPU rungs are for phishing-simulation-only instances: anything serving training content or running the recurring automations carries an 8-vCore floor."
  }
}

variable "target_cpu_percent" {
  description = "Target average CPU utilization (percent, 1-100) for the VMSS autoscale policy."
  type        = number
  default     = 60
}

variable "db_sku_name" {
  type    = string
  default = "GP_Standard_D4ds_v5"
}

variable "db_storage_mb" {
  description = "Storage size in MiB for the PostgreSQL Flexible Server. Minimum 32768 MiB (32 GiB); autoscaling grows in 32 GiB increments."
  type        = number
  default     = 262144
}

variable "db_version" {
  type    = string
  default = "16"
}

variable "db_backup_retention_days" {
  description = "Days Azure Database for PostgreSQL retains automated backups. Azure Flexible Server enforces a minimum of 7 and a maximum of 35."
  type        = number
  default     = 30
}

variable "db_replica_count" {
  description = "Number of Azure Database for PostgreSQL read replicas."
  type        = number
  default     = 2
}

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
  description = "Provision a Storage Account + immutable container for pre-patch /api/instance/export bundles."
  type        = bool
  default     = true
}

variable "backup_storage_account_name" {
  description = "Name of an existing Storage Account to use. If null and create_backup_storage_account is true, the module names one."
  type        = string
  default     = null
}

variable "backup_storage_replication" {
  description = "Replication type for the backup storage account. ZRS is the procurement-grade default; GRS adds cross-region replica."
  type        = string
  default     = "ZRS"
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
  description = "Front the LB topology with an Azure Application Gateway. Required for WAF parity with the AWS ALB+WAF story."
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
  description = "Provision an Azure Cache for Redis (Standard or Premium SKU). Required for horizontal scaling; set to false only when supplying redis_endpoint_override."
  type        = bool
  default     = true
}

variable "redis_sku_name" {
  description = "Redis SKU. Standard delivers a primary/replica pair; Premium adds zone selection. Basic is single-node and breaks horizontal scaling (validated)."
  type        = string
  default     = "Standard"
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
