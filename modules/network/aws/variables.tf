variable "name_prefix" {
  description = "Prefix for all network resource names (e.g. 'hailbytes-asm-prod')."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC. /16 is recommended; the module subdivides it into /24 subnets across the chosen AZs."
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones to span. 2 is sufficient for single-vm and ha-hot-hot; use 3 for unlimited-scale."
  type        = number
  default     = 2
  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3."
  }
}

variable "enable_nat_gateway" {
  description = "Provision one NAT Gateway per AZ for private-subnet egress. Disable if you have a transit gateway or central egress account."
  type        = bool
  default     = true
}

variable "enable_flow_logs" {
  description = "Enable VPC Flow Logs to CloudWatch."
  type        = bool
  default     = true
}

variable "flow_logs_retention_days" {
  type    = number
  default = 30
}

variable "tags" {
  type    = map(string)
  default = {}
}
