# Variables for SAT on Azure (single)
# Mirrors modules/single-vm/azure/variables.tf (without `product`,
# which is hardcoded by this wrapper).

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
}

variable "admin_username" {
  description = "Initial admin username (used only for emergency console access; prefer Azure AD login via Bastion)."
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key for the admin user. Required by Azure Linux VMs."
  type        = string
}

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
  description = "Install an Azure Run Command document named RunPrePatchBackup."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags applied to every resource."
  type        = map(string)
  default     = {}
}
