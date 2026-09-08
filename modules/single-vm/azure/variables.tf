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
  description = "Replication type for the backup storage account. GRS (geo-redundant, cross-region) is the default and the strongest option this account can take: account_kind is BlobStorage, which supports LRS, GRS and RAGRS only -- the zone-redundant tiers (ZRS, GZRS, RAGZRS) are a StorageV2/BlockBlobStorage feature and Azure rejects them here at apply time. For backup bundles cross-region beats zone-local anyway: GRS survives the loss of the whole region, ZRS only the loss of a zone."
  type        = string
  default     = "GRS"

  validation {
    condition     = contains(["LRS", "GRS", "RAGRS"], var.backup_storage_replication)
    error_message = "backup_storage_replication must be LRS, GRS or RAGRS. The backup account is account_kind = \"BlobStorage\" (blob-only, chosen so the azurerm provider makes no queue-service call over a data plane this account closes), and that kind does not offer the zone-redundant tiers -- Azure fails the apply with \"`account_replication_type` of `ZRS` isn't supported for Blob Storage accounts\" partway through, after other resources are already built."
  }
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
