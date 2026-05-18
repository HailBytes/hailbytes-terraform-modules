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

variable "tags" {
  description = "Additional tags applied to every resource."
  type        = map(string)
  default     = {}
}
