# Variables for SAT on AWS (ha)
# Mirrors modules/ha-hot-hot/aws/variables.tf (without `product`,
# which is hardcoded by this wrapper).

variable "vpc_id" {
  description = "VPC to deploy into."
  type        = string
}

variable "public_subnet_ids" {
  description = "At least two public subnet IDs in different AZs for the ALB."
  type        = list(string)
  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "At least two subnets in different AZs are required for HA."
  }
}

variable "private_subnet_ids" {
  description = "At least two private subnet IDs in different AZs. One VM and one DB subnet per AZ."
  type        = list(string)
  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "At least two private subnets in different AZs are required for HA."
  }
}

variable "allowed_cidrs" {
  description = "CIDR blocks permitted to reach the ALB on port 443."
  type        = list(string)
}

variable "acm_certificate_arn" {
  description = "ARN of an ACM certificate in the same region for the ALB HTTPS listener."
  type        = string
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "name_prefix" {
  type    = string
  default = null
}

variable "instance_type" {
  type    = string
  default = "t3.large"
}

variable "data_volume_size_gb" {
  type    = number
  default = 200
}

variable "key_name" {
  type    = string
  default = null
}

variable "db_instance_class" {
  type    = string
  default = "db.t3.medium"
}

variable "db_allocated_storage_gb" {
  type    = number
  default = 100
}

variable "db_max_allocated_storage_gb" {
  description = "Storage autoscaling cap."
  type        = number
  default     = 500
}

variable "db_engine_version" {
  description = "Postgres engine version. Pin in production."
  type        = string
  default     = "16.4"
}

variable "db_backup_retention_days" {
  type    = number
  default = 14
}

variable "db_deletion_protection" {
  type    = bool
  default = true
}

variable "enable_customer_managed_key" {
  type    = bool
  default = false
}

variable "alb_idle_timeout_seconds" {
  type    = number
  default = 120
}

variable "alb_min_tls_version" {
  description = "Minimum TLS version on the ALB HTTPS listener."
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-2021-06"
}

variable "enable_management_access" {
  description = "Attach SSM Session Manager policy to instance role."
  type        = bool
  default     = true
}

variable "marketplace_product_code" {
  description = "Optional AWS Marketplace product code for stricter AMI lookup. See module README for the lookup command."
  type        = string
  default     = null
}

variable "enable_http_redirect" {
  description = "Add an HTTP:80 listener on the ALB that 301-redirects to HTTPS. Convenient when customers hit the bare hostname."
  type        = bool
  default     = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
