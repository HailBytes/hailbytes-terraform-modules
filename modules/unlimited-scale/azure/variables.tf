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
variable "allowed_cidrs" { type = list(string) }
variable "admin_username" { type = string }
variable "ssh_public_key" { type = string }

# ----- VMSS sizing -----

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

# ----- DB sizing -----

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

variable "tags" {
  type    = map(string)
  default = {}
}
