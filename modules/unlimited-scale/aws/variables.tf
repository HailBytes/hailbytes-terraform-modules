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

variable "enable_alb_deletion_protection" {
  description = "Enable deletion protection on the ALB. Default true; production deployments should keep this on. Set to false in dev/test sandboxes where `terraform destroy` should succeed without manual cleanup."
  type        = bool
  default     = true
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
  description = "Days RDS retains automated daily backups. 30 covers a typical monthly review cycle and aligns with the pre-patch on-demand snapshot lifecycle."
  type        = number
  default     = 30
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
  description = "Provision an S3 bucket (versioning + object-lock governance + lifecycle to IA at 30d and Deep Archive at 90d) for pre-patch /api/instance/export bundles. The SAT instance profile gets least-privilege PutObject on hailbytes-*.tar.gz."
  type        = bool
  default     = true
}

variable "backup_bucket_name" {
  description = "Name of an existing S3 bucket to use for pre-patch backups. If null and create_backup_bucket is true, the module names one '<name_prefix>-backups-<account_id>'. If non-null and create_backup_bucket is false, the module only attaches the IAM PutObject policy to the existing bucket."
  type        = string
  default     = null
}

variable "backup_object_lock_retention_days" {
  description = "Object Lock (governance mode) retention period for backup objects. 30 days satisfies the procurement-grade safety net while still allowing privileged operator override for compaction."
  type        = number
  default     = 30
}

variable "backup_noncurrent_version_expiration_days" {
  description = "Expire noncurrent versions of backup objects after this many days. 365 retains a year of pre-patch bundles for rollback."
  type        = number
  default     = 365
}

variable "instance_refresh_min_healthy_percentage" {
  description = "Minimum percentage of the ASG that must remain healthy during an instance refresh. 50 drains one instance at a time on a 2-instance ASG; tune higher for larger fleets that can tolerate parallel replacement."
  type        = number
  default     = 50
}

variable "instance_refresh_instance_warmup_seconds" {
  description = "Seconds the ASG considers a new instance 'warming up' before counting toward healthy_percentage. 120 is enough for the SAT marketplace AMI to pass the ALB /health probe; raise for slower boot images."
  type        = number
  default     = 120
}

variable "refresh_rollback_5xx_threshold_pct" {
  description = "Target-group 5xx rate (percent) above which the instance refresh auto-rollback alarm fires. Default 1% over 2 evaluation periods of 1 minute."
  type        = number
  default     = 1
}

variable "waf_web_acl_arn" {
  description = "Optional ARN of an existing WAFv2 web ACL to associate with the ALB. Defaults to null (not attached). HailBytes does not bundle a managed ruleset; most enterprises bring their own."
  type        = string
  default     = null
}

variable "rds_copy_tags_to_snapshot" {
  description = "Propagate tags from the RDS instance to automated and on-demand snapshots."
  type        = bool
  default     = true
}

variable "schema_version_endpoint_path" {
  description = "Path on the SAT/ASM API that returns the running schema version. Used by the schema_version_endpoint output that customer CI/CD curls in post-patch verification."
  type        = string
  default     = "/api/instance/schema-version"
}


# ----- RDS production-hardening (opt-in) -----

variable "rds_enhanced_monitoring_interval" {
  description = "RDS enhanced monitoring sample interval in seconds. 0 disables. Default 0; production typically 60. CKV_AWS_118."
  type        = number
  default     = 0
  validation {
    condition     = contains([0, 1, 5, 10, 15, 30, 60], var.rds_enhanced_monitoring_interval)
    error_message = "rds_enhanced_monitoring_interval must be one of: 0, 1, 5, 10, 15, 30, 60."
  }
}

variable "rds_enabled_cloudwatch_log_types" {
  description = "RDS log types to export to CloudWatch. Empty list = none (cost-saving default). Production should set [\"postgresql\", \"upgrade\"]. CKV_AWS_129."
  type        = list(string)
  default     = []
}

variable "rds_iam_authentication_enabled" {
  description = "Enable IAM database authentication on RDS. CKV_AWS_161."
  type        = bool
  default     = false
}

variable "rds_performance_insights_enabled" {
  description = "Enable RDS Performance Insights. CKV_AWS_354."
  type        = bool
  default     = false
}

variable "rds_performance_insights_retention_days" {
  description = "Performance Insights data retention. 7 = free tier (default); 731 = long-term."
  type        = number
  default     = 7
}

variable "tags" {
  type    = map(string)
  default = {}
}
