# Variables for SAT on Azure (autoscale)
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

variable "vmss_min_count" {
  type    = number
  default = 3
}

variable "vmss_max_count" {
  type    = number
  default = 20
}

variable "vmss_default_count" {
  type    = number
  default = 3
}

variable "vm_size" {
  type    = string
  default = "Standard_D2s_v5"
}

variable "target_cpu_percent" {
  type    = number
  default = 60
}

variable "db_sku_name" {
  type    = string
  default = "GP_Standard_D4ds_v5"
}

variable "db_storage_mb" {
  type    = number
  default = 262144
}

variable "db_version" {
  type    = string
  default = "16"
}

variable "db_backup_retention_days" {
  type    = number
  default = 30
}

variable "db_replica_count" {
  type    = number
  default = 2
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
  description = "Name of an existing Storage Account to use."
  type        = string
  default     = null
}

variable "backup_storage_replication" {
  description = "Replication type for the backup storage account."
  type        = string
  default     = "ZRS"
}

variable "backup_immutability_days" {
  description = "Days the immutable blob policy keeps backup objects pinned."
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
  description = "Install a VMSS extension that bakes the pre-patch backup script."
  type        = bool
  default     = true
}

variable "rolling_upgrade_max_batch_percent" {
  description = "VMSS rolling-upgrade batch size as a percentage of total instances."
  type        = number
  default     = 20
}

variable "rolling_upgrade_max_unhealthy_percent" {
  description = "Maximum percentage of unhealthy VMSS instances permitted before the upgrade pauses."
  type        = number
  default     = 20
}

variable "enable_application_gateway" {
  description = "Front the VMSS topology with Azure Application Gateway (required for WAF parity with AWS ALB+WAF)."
  type        = bool
  default     = false
}

variable "appgw_subnet_id" {
  description = "Subnet for the Application Gateway. Required when enable_application_gateway = true."
  type        = string
  default     = null
}

variable "appgw_tls_pfx_base64" {
  description = "Base64-encoded PFX for the App Gateway HTTPS listener."
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
  description = "Backend 5xx response count threshold for the App Gateway rolling-upgrade tripwire."
  type        = number
  default     = 50
}

variable "schema_version_endpoint_path" {
  description = "Path on the SAT API that returns the running schema version."
  type        = string
  default     = "/api/instance/schema-version"
}

variable "enable_post_patch_run_command" {
  description = "Install a VMSS extension named RunPostPatchVerify mirroring the AWS sat-aws-autoscale aws_ssm_document.post_patch_verify."
  type        = bool
  default     = true
}

# ----- Shared session store (Azure Cache for Redis) -----

variable "enable_managed_redis" {
  description = "Provision an Azure Cache for Redis. Required for horizontal scaling; set to false only when supplying redis_endpoint_override."
  type        = bool
  default     = true
}

variable "redis_sku_name" {
  description = "Redis SKU. Standard or Premium only (Basic is single-node)."
  type        = string
  default     = "Standard"
}

variable "redis_family" {
  type    = string
  default = "C"
}

variable "redis_capacity" {
  description = "Redis capacity (size index). 0-6 for Standard. Scale alongside VMSS instance count."
  type        = number
  default     = 1
}

variable "redis_endpoint_override" {
  description = "Host of an existing customer-managed Redis endpoint."
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
  description = "Hours until the Key Vault DB-password secret expires. Default 8760 = one calendar year."
  type        = number
  default     = 8760
}


variable "postgres_geo_redundant_backup_enabled" {
  description = "Enable geo-redundant backup on Postgres Flexible Server. CKV_AZURE_136."
  type        = bool
  default     = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
