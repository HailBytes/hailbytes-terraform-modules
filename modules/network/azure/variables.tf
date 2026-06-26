variable "name_prefix" {
  description = "Prefix for all network resource names."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group to create the network resources in. Must already exist."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "vnet_address_space" {
  description = "CIDR for the virtual network. /16 recommended; module subdivides into /24 subnets."
  type        = string
  default     = "10.30.0.0/16"
}

variable "workload_subnet_prefix" {
  description = "CIDR for the workload (VM/VMSS) subnet."
  type        = string
  default     = "10.30.10.0/24"
}

variable "db_subnet_prefix" {
  description = "CIDR for the Postgres Flexible Server delegated subnet."
  type        = string
  default     = "10.30.20.0/24"
}

variable "lb_subnet_prefix" {
  description = "CIDR for an LB / public-facing subnet. If you only use a public LB you can leave this unused."
  type        = string
  default     = "10.30.0.0/24"
}

variable "associate_subnet_nsgs" {
  description = "Associate the module-created baseline NSGs with the lb/workload/db subnets. Set to false when composing this module with a workload tier module that associates its own NSG to the same subnet (Azure allows only one NSG per subnet)."
  type        = bool
  default     = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
