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
  description = "Tags to apply to all network resources created by this module."
  type        = map(string)
  default     = {}
}

variable "enable_nat_gateway" {
  description = "Provision a NAT Gateway and associate it with the workload subnet. Required for the VMs to reach anything outbound: a Standard Load Balancer gives its backend pool no outbound SNAT, and the VMs have no public IP. Defaults true, matching enable_nat_gateway in modules/network/aws. Costs roughly EUR 28.84 / USD 32.85 per month plus EUR 0.0395 / USD 0.045 per GB processed — the per-GB charge applies to traffic bound for Azure services too, so pair it with service endpoints for Storage and Key Vault."
  type        = bool
  default     = true
}

variable "nat_gateway_idle_timeout_minutes" {
  description = "TCP idle timeout for the NAT Gateway, in minutes (4-120)."
  type        = number
  default     = 10
  validation {
    condition     = var.nat_gateway_idle_timeout_minutes >= 4 && var.nat_gateway_idle_timeout_minutes <= 120
    error_message = "nat_gateway_idle_timeout_minutes must be between 4 and 120."
  }
}
