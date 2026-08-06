# Variables for SAT on Azure (ha)
# Mirrors modules/ha-hot-hot/azure/variables.tf (without `product`,
# which is hardcoded by this wrapper).

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
  description = "Default action for the Key Vault network ACL. 'Allow' preserves the pre-network-ACL behavior (public endpoint open, RBAC-gated); set 'Deny' once you've added the operator IP to key_vault_ip_rules and the Microsoft.KeyVault service endpoint on vm_subnet_id. AzureServices bypass is always on so the VMs' managed identities can read secrets either way."
  type        = string
  default     = "Allow"
}

variable "associate_vm_subnet_nsg" {
  description = "Associate the module-managed NSG (allow-https-* rules built from allowed_cidrs) with vm_subnet_id. Only applies when vm_subnet_id differs from lb_subnet_id (when they're the same subnet, the lb NSG already covers it). Set false if the subnet already has an NSG attached and your landing-zone tooling manages ingress; the NSG ID is still exported as vm_nsg_id for you to reference."
  type        = bool
  default     = true
}

variable "key_vault_ip_rules" {
  description = "IPv4 addresses or CIDRs allowed to reach the Key Vault data plane (typically the operator IP running terraform apply, or your bastion's egress NAT). Required only when default_action = Deny and you don't have Private Link configured."
  type        = list(string)
  default     = []
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "name_prefix" {
  type    = string
  default = null
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
}

variable "redis_family" {
  description = "Redis SKU family. 'C' = Standard/Basic, 'P' = Premium. Must match redis_sku_name."
  type        = string
  default     = "C"
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
  description = "Port the HailBytes admin server listens on. Used by the post-patch verifier, which probes the instance over localhost."
  type        = number
  default     = 3333
}

variable "external_db_host" {
  description = "Hostname or private IP of a customer-operated PostgreSQL server. Required when db_mode = \"external\", ignored otherwise. Must be resolvable and reachable from vm_subnet_id."
  type        = string
  default     = null
}

variable "external_db_port" {
  description = "Port of the customer-operated PostgreSQL server."
  type        = number
  default     = 5432
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
  description = "Password for external_db_username. Required when db_mode = \"external\". Written to the deployment's Key Vault; supply it through a tfvars file or TF_VAR_ environment variable, never a literal in version control."
  type        = string
  default     = null
  sensitive   = true
}

variable "external_db_sslmode" {
  description = "libpq sslmode for the connection to the customer-operated server. 'require' is the minimum accepted; 'verify-full' is recommended."
  type        = string
  default     = "require"
}

variable "appgw_backend_protocol" {
  description = "Protocol for the App Gateway -> VM hop. \"Http\" terminates TLS at the gateway. \"Https\" gives end-to-end encryption but requires appgw_backend_root_cert_pem and appgw_backend_host_header — App Gateway v2 validates the backend certificate."
  type        = string
  default     = "Http"
}

variable "appgw_backend_port" {
  description = "Port App Gateway connects to on the VMs. 443 pairs with Https; 80 pairs with Http."
  type        = number
  default     = 80
}

variable "appgw_backend_root_cert_pem" {
  description = "PEM-encoded root certificate of the backend server certificate, uploaded as an App Gateway trusted root. Required when appgw_backend_protocol = \"Https\"."
  type        = string
  default     = null
}

variable "enable_diagnostics" {
  description = "Send load-balancer, database, cache and Application Gateway diagnostics to a Log Analytics workspace. Log Analytics ingestion is billed per GB by Azure."
  type        = bool
  default     = true
}

variable "log_analytics_workspace_id" {
  description = "Resource ID of an existing Log Analytics workspace. Leave null and the module creates one; supply your landing zone's central workspace if you have one."
  type        = string
  default     = null
}

variable "diagnostics_retention_days" {
  description = "Retention for the module-created Log Analytics workspace. Ignored when log_analytics_workspace_id is supplied."
  type        = number
  default     = 30
}

variable "enable_management_access" {
  description = "Install AADSSHLoginForLinux on each app VM for Entra-authenticated, RBAC-gated SSH via `az ssh vm` with no public IP. Operators still need the Virtual Machine Administrator Login or User Login role assigned."
  type        = bool
  default     = false
}
