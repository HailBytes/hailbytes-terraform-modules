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
  description = "Subnet for VMs. Must be in a vnet that also contains delegated subnet for Flexible Server Postgres."
  type        = string
}

variable "db_delegated_subnet_id" {
  description = "Subnet delegated to Microsoft.DBforPostgreSQL/flexibleServers (vnet-integrated Postgres)."
  type        = string
}

variable "private_dns_zone_id" {
  description = "Private DNS zone ID for postgres.database.azure.com (linked to the vnet)."
  type        = string
}

variable "lb_subnet_id" {
  description = "Subnet for the internal Standard Load Balancer frontend. Often the same as vm_subnet_id."
  type        = string
}

variable "allowed_cidrs" {
  type = list(string)
}

variable "admin_username" {
  type = string
}

variable "ssh_public_key" {
  type = string
}

# ----- Key Vault network ACL -----

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

variable "vm_size" {
  type    = string
  default = "Standard_D2s_v5"
}

variable "data_disk_size_gb" {
  type    = number
  default = 256
}

variable "enable_customer_managed_key" {
  description = "Encrypt VM OS and data disks with a customer-managed key (RSA-4096 in this module's Key Vault, via a disk encryption set) instead of platform-managed keys. Matches the single-vm tier's CMK option."
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
}

variable "db_version" {
  type    = string
  default = "16"
}

variable "db_backup_retention_days" {
  type    = number
  default = 14
}

variable "db_high_availability_mode" {
  description = "ZoneRedundant gives HA across availability zones; SameZone is cheaper but lower SLA."
  type        = string
  default     = "ZoneRedundant"
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

variable "db_mode" {
  description = "Database backend. 'flexible_server' (default) provisions Azure Database for PostgreSQL Flexible Server — recommended for production. 'vm' provisions a third Linux VM with self-managed Postgres 16 for customers that must keep data plane on a VM."
  type        = string
  default     = "flexible_server"
  validation {
    condition     = contains(["flexible_server", "vm"], var.db_mode)
    error_message = "db_mode must be one of: flexible_server, vm."
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
  description = "Replication type for the backup storage account. ZRS is the procurement-grade default."
  type        = string
  default     = "ZRS"
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
  description = "Install an Azure Run Command document named RunPrePatchBackup on the first SAT VM. Customers fire it from the Portal."
  type        = bool
  default     = true
}

variable "enable_post_patch_run_command" {
  description = "Install an Azure Run Command document named RunPostPatchVerify on each VM, mirroring the AWS aws_ssm_document.post_patch_verify in the SAT/ASM aws-ha modules. Customers fire it from the Portal after a Run Command-driven image swap."
  type        = bool
  default     = true
}

# ----- Shared session store (Azure Cache for Redis) -----

variable "enable_managed_redis" {
  description = "Provision an Azure Cache for Redis (Standard or Premium SKU, zone-redundant in Premium). Required for HA; set to false only when supplying redis_endpoint_override."
  type        = bool
  default     = true
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

variable "appgw_subnet_id" {
  description = "Subnet for the Application Gateway. Required when enable_application_gateway = true. Must be /24 or larger, in the same vnet as the VMs."
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
  description = "Optional Host header App Gateway sends to the SAT backend pool. Leave null to use the backend's IP."
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
