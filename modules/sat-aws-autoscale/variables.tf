# Variables for SAT on AWS (autoscale)
# Mirrors modules/unlimited-scale/aws/variables.tf (without `product`,
# which is hardcoded by this wrapper).

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

variable "marketplace_product_code" {
  description = "Optional AWS Marketplace product code for stricter AMI lookup. See module README for the lookup command."
  type        = string
  default     = null
}

variable "enable_http_redirect" {
  description = "Add an HTTP:80 listener that 301-redirects to HTTPS. Convenient when customers hit the bare hostname."
  type        = bool
  default     = true
}

# ----- Patching and migration safety -----

variable "create_backup_bucket" {
  description = "Provision an S3 bucket with versioning + object-lock + lifecycle for pre-patch /api/instance/export bundles."
  type        = bool
  default     = true
}

variable "backup_bucket_name" {
  description = "Name of an existing S3 bucket to use for pre-patch backups."
  type        = string
  default     = null
}

variable "backup_object_lock_retention_days" {
  description = "Object Lock (governance mode) retention period for backup objects."
  type        = number
  default     = 30
}

variable "backup_noncurrent_version_expiration_days" {
  description = "Expire noncurrent versions of backup objects after this many days."
  type        = number
  default     = 365
}

variable "instance_refresh_min_healthy_percentage" {
  description = "Minimum percentage of the ASG that must remain healthy during an instance refresh."
  type        = number
  default     = 50
}

variable "instance_refresh_instance_warmup_seconds" {
  description = "Seconds the ASG considers a new instance 'warming up' before counting toward healthy_percentage."
  type        = number
  default     = 120
}

variable "refresh_rollback_5xx_threshold_pct" {
  description = "Target-group 5xx rate (percent) that triggers instance-refresh auto-rollback."
  type        = number
  default     = 1
}

variable "waf_web_acl_arn" {
  description = "Optional ARN of an existing WAFv2 web ACL to associate with the ALB."
  type        = string
  default     = null
}

variable "rds_copy_tags_to_snapshot" {
  description = "Propagate tags from the RDS instance to automated and on-demand snapshots."
  type        = bool
  default     = true
}

variable "schema_version_endpoint_path" {
  description = "Path on the SAT API that returns the running schema version."
  type        = string
  default     = "/api/instance/schema-version"
}

# ----- Shared session store (ElastiCache for Redis) -----

variable "enable_managed_redis" {
  description = "Provision an ElastiCache Multi-AZ replication group. Required for horizontal scaling; set to false only when supplying redis_endpoint_override."
  type        = bool
  default     = true
}

variable "redis_node_type" {
  description = "ElastiCache node type. Scale up alongside ASG growth — cache.t4g.small handles 3-5 instances, cache.m6g.large handles 10-20+."
  type        = string
  default     = "cache.t4g.small"
}

variable "redis_engine_version" {
  type    = string
  default = "7.1"
}

variable "redis_snapshot_retention_days" {
  type    = number
  default = 0
}

variable "redis_endpoint_override" {
  description = "Host of an existing customer-managed Redis endpoint. Pair with enable_managed_redis = false."
  type        = string
  default     = null
}

variable "redis_endpoint_override_port" {
  type    = number
  default = 6379
}

variable "redis_endpoint_override_tls" {
  type    = bool
  default = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
