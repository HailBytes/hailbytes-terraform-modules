# ----- Required -----

variable "product" {
  description = "HailBytes product to deploy. Must match an active Azure Marketplace subscription on this tenant."
  type        = string
  validation {
    condition     = contains(["asm", "sat"], var.product)
    error_message = "product must be one of: asm, sat."
  }
}

variable "resource_group_name" {
  description = "Resource group to deploy into. Must already exist."
  type        = string
}

variable "location" {
  description = "Azure region (e.g. eastus, westeurope)."
  type        = string
}

variable "subnet_id" {
  description = "Subnet resource ID to deploy the VM NIC into."
  type        = string
}

variable "allowed_cidrs" {
  description = "CIDR blocks permitted to reach the VM on port 443."
  type        = list(string)
  validation {
    condition     = alltrue([for c in var.allowed_cidrs : can(cidrhost(c, 0))])
    error_message = "Each entry in allowed_cidrs must be a valid CIDR block (e.g. 10.0.0.0/8)."
  }
}

variable "admin_username" {
  description = "Initial admin username (used only for emergency console access; prefer Azure AD login via Bastion)."
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key for the admin user. Required by Azure Linux VMs."
  type        = string
}

# ----- Optional -----

variable "environment" {
  description = "Environment tag (e.g. dev, staging, prod)."
  type        = string
  default     = "dev"
}

variable "name_prefix" {
  description = "Prefix for resource names. Defaults to 'hailbytes-{product}-{environment}'."
  type        = string
  default     = null
}

variable "vm_size" {
  description = "VM SKU. Standard_D2s_v5 is the default for ASM/SAT single-vm tier."
  type        = string
  default     = "Standard_D2s_v5"
}

variable "os_disk_size_gb" {
  description = "OS disk size in GB."
  type        = number
  default     = 64
}

variable "data_disk_size_gb" {
  description = "Data disk size in GB. Attached at LUN 0; the marketplace image mounts and formats on first boot."
  type        = number
  default     = 256
}

variable "enable_customer_managed_key" {
  description = "Use a customer-managed Key Vault key for disk encryption. If false, uses platform-managed keys."
  type        = bool
  default     = false
}

variable "key_vault_id" {
  description = "Existing Key Vault resource ID. Required if enable_customer_managed_key = true."
  type        = string
  default     = null
}

variable "associate_public_ip" {
  description = "Attach a public IP. Disabled by default; deploy behind Azure Bastion or a load balancer."
  type        = bool
  default     = false
}

variable "allow_internet_ingress" {
  description = "Permit 0.0.0.0/0 in allowed_cidrs. You take responsibility."
  type        = bool
  default     = false
}

variable "accept_marketplace_terms" {
  description = "If true, the module creates an azurerm_marketplace_agreement to accept legal terms on first apply. Set to false if you accept terms separately (e.g. via portal or central governance)."
  type        = bool
  default     = true
}

variable "marketplace_sku_override" {
  description = "Override the marketplace SKU (plan name). Defaults to the offer slug for each product, which matches the most common published plan. Set this if your Azure Marketplace subscription points at a different plan name."
  type        = string
  default     = null
}

variable "marketplace_image_version" {
  description = "Marketplace image version to deploy. 'latest' pulls the newest published version; pin to an explicit version (e.g. '1.2.3') for reproducible production deploys."
  type        = string
  default     = "latest"
}

# ----- Patching and migration safety -----

variable "create_backup_storage_account" {
  description = "Provision an Azure Storage Account + container (blob versioning + immutable WORM policy in unlocked mode + lifecycle to Cool at 30d and Archive at 90d) for pre-patch /api/instance/export bundles. The VM's system-assigned managed identity gets Storage Blob Data Contributor on the container only."
  type        = bool
  default     = true
}

variable "backup_storage_account_name" {
  description = "Name of an existing Storage Account to use. If null and create_backup_storage_account is true, the module names one (lowercase, alphanumeric, max 24 chars). If non-null and create_backup_storage_account is false, the module only grants the managed identity blob writer perms on it."
  type        = string
  default     = null
}

variable "backup_storage_replication" {
  description = "Replication type for the backup storage account. ZRS (zone-redundant) is the recommended default for procurement-grade durability. GRS adds cross-region replica."
  type        = string
  default     = "ZRS"
}

variable "backup_immutability_days" {
  description = "Days the immutable blob policy keeps backup objects pinned. Set in unlocked mode so customers can extend later through portal/CLI."
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
  description = "Install an Azure Run Command document named RunPrePatchBackup. Customers can fire it from the Portal (VM -> Operations -> Run command) to take a pre-patch backup + managed-disk snapshot in one click. Disable if your AMI does not yet bundle ha-pre-patch-backup.sh."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags applied to every resource."
  type        = map(string)
  default     = {}
}
