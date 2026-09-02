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
    error_message = "All allowed_cidrs entries must be valid CIDR blocks (e.g. \"10.0.0.0/8\")."
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
    error_message = "vm_size must be a portable HailBytes rung: Standard_B2s or Standard_D2s_v5 (2 vCPU), Standard_D4s_v5 (4), Standard_D8s_v5 (8), Standard_D16s_v5 (16), Standard_D32s_v5 (32), Standard_D48s_v5 (48), Standard_D64s_v5 (64). Azure Dsv5 has NO general-purpose size between 16 and 32 vCPU -- there is no Standard_D24s_v5 -- so a 24-vCore deployment cannot be delivered as one VM or as a symmetric pair; quote 16 or 32. The 2 and 4 vCPU rungs carry measured training capacity as of 2026-08-24 and are supported for pilots and small rosters; 8 remains the default and the published purchasable rung. Size from measured load rather than from the rung -- see hailbytes-sat/docs/VM_SCALING.md."
  }
}

variable "os_disk_size_gb" {
  description = "OS disk size in GB."
  type        = number
  default     = 100
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

variable "phish_allowed_cidrs" {
  description = "CIDRs permitted to reach the phishing/landing surface (SAT only; ASM has no such surface). Leave null to inherit allowed_cidrs, which is the historical behaviour and keeps existing deployments planning clean. Set it whenever the simulation targets are not inside the admin allow-list -- with one shared list, locking the console to an office range also locks every target out of the landing pages, and the campaign sends and then records no interactions. \"0.0.0.0/0\" is the usual value for a live simulation and is accepted here without allow_internet_ingress: that flag guards the admin surface, and requiring it would re-couple the two lists this variable exists to separate."
  type        = list(string)
  default     = null

  validation {
    condition     = alltrue([for c in coalesce(var.phish_allowed_cidrs, []) : can(cidrhost(c, 0))])
    error_message = "All phish_allowed_cidrs entries must be valid CIDR blocks (e.g. \"0.0.0.0/0\")."
  }
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
  description = "Provision an Azure Storage Account + container (blob versioning + immutable WORM policy in unlocked mode + lifecycle to Cool at 30d and Archive at 90d) for pre-patch /api/instance/export bundles. The VM's system-assigned managed identity gets Storage Blob Data Contributor on the container only."
  type        = bool
  default     = false
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

variable "admin_port" {
  description = "Port the admin UI listens on inside the VM. Leave null to derive it from `product`: 3333 for SAT (the image's config.json `listen_url`), 443 for ASM (its proxy container publishes 443). Set it only if you have changed the port inside the image."
  type        = number
  default     = null
}

variable "phish_port" {
  description = "Port the phishing/tracking server listens on inside the VM. SAT only -- it is the landing-page and interaction-tracking surface, which is the product. Ignored when `product` is \"asm\", which has no phishing surface. Leave null for the image default of 80."
  type        = number
  default     = null
}
