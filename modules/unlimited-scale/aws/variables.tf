# ----- Required -----

variable "product" {
  type = string
  validation {
    condition     = contains(["asm", "sat"], var.product)
    error_message = "product must be one of: asm, sat."
  }
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "At least two public subnets are required."
  }
}

variable "private_subnet_ids" {
  type = list(string)
  validation {
    condition     = length(var.private_subnet_ids) >= 3
    error_message = "At least three private subnets (one per AZ) are required for unlimited-scale."
  }
}

variable "allowed_cidrs" {
  type = list(string)
}

variable "acm_certificate_arn" {
  type = string
}

variable "alert_email" {
  description = "Email subscribed to the alarm SNS topic. Pass null to skip."
  type        = string
  default     = null
}

# ----- ASG sizing -----

variable "asg_min_size" {
  type    = number
  default = 3
}

variable "asg_max_size" {
  type    = number
  default = 20
}

variable "asg_desired_capacity" {
  type    = number
  default = 3
}

variable "instance_type" {
  type    = string
  default = "m6i.large"
}

variable "target_cpu_utilization" {
  type    = number
  default = 60
}

variable "target_request_count_per_target" {
  type    = number
  default = 500
}

# ----- DB sizing -----

variable "db_instance_class" {
  type    = string
  default = "db.r6g.large"
}

variable "db_allocated_storage_gb" {
  type    = number
  default = 200
}

variable "db_max_allocated_storage_gb" {
  type    = number
  default = 2000
}

variable "db_engine_version" {
  type    = string
  default = "16.4"
}

variable "db_backup_retention_days" {
  type    = number
  default = 30
}

variable "db_read_replica_count" {
  type    = number
  default = 2
}

variable "db_deletion_protection" {
  type    = bool
  default = true
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

variable "enable_customer_managed_key" {
  type    = bool
  default = true
}

variable "alb_min_tls_version" {
  type    = string
  default = "ELBSecurityPolicy-TLS13-1-2-2021-06"
}

variable "enable_flow_logs" {
  type    = bool
  default = true
}

variable "access_log_retention_days" {
  type    = number
  default = 90
}

variable "tags" {
  type    = map(string)
  default = {}
}
