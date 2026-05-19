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
  description = "Deprecated alias for rds_backup_retention_period. Kept for backward compatibility."
  type        = number
  default     = null
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

# ----- Patching and migration safety -----

variable "db_mode" {
  description = "Database backend. 'rds' (default) provisions a Multi-AZ RDS instance. 'ec2' provisions a third EC2 with self-managed Postgres 16."
  type        = string
  default     = "rds"
  validation {
    condition     = contains(["rds", "ec2"], var.db_mode)
    error_message = "db_mode must be one of: rds, ec2."
  }
}

variable "db_ec2_instance_type" {
  description = "EC2 instance type for the self-managed Postgres VM when db_mode = ec2."
  type        = string
  default     = "m6i.large"
}

variable "db_ec2_data_volume_size_gb" {
  description = "Size of the encrypted gp3 volume backing /var/lib/postgresql on the self-managed Postgres VM."
  type        = number
  default     = 200
}

variable "rds_backup_retention_period" {
  description = "Days RDS retains automated daily backups."
  type        = number
  default     = 7
}

variable "rds_copy_tags_to_snapshot" {
  description = "Propagate tags from the RDS instance to automated and on-demand snapshots."
  type        = bool
  default     = true
}

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

variable "refresh_rollback_5xx_threshold_pct" {
  description = "Target-group 5xx rate (percent) that trips the patching alarm."
  type        = number
  default     = 1
}

variable "waf_web_acl_arn" {
  description = "Optional ARN of an existing WAFv2 web ACL to associate with the ALB. Defaults to null."
  type        = string
  default     = null
}

variable "alert_email" {
  description = "Email subscribed to the patching alarm SNS topic. Pass null to skip."
  type        = string
  default     = null
}

variable "schema_version_endpoint_path" {
  description = "Path on the SAT API that returns the running schema version."
  type        = string
  default     = "/api/instance/schema-version"
}

# ----- Shared session store (ElastiCache for Redis) -----

variable "enable_managed_redis" {
  description = "Provision an ElastiCache Multi-AZ replication group for HailBytes shared sessions and worker locks. HA mode requires a shared Redis endpoint — set to false only if you supply redis_endpoint_override."
  type        = bool
  default     = true
}

variable "redis_node_type" {
  description = "ElastiCache node type. cache.t4g.small is the procurement-friendly default; raise for higher session-throughput deployments."
  type        = string
  default     = "cache.t4g.small"
}

variable "redis_engine_version" {
  description = "ElastiCache Redis engine version."
  type        = string
  default     = "7.1"
}

variable "redis_snapshot_retention_days" {
  description = "Days ElastiCache retains daily snapshots. Sessions are recoverable from Postgres re-login, so this defaults to 0; raise if you want a Redis PITR window."
  type        = number
  default     = 0
}

variable "redis_endpoint_override" {
  description = "Host of a customer-managed Redis endpoint. When non-null, the module skips its own ElastiCache replication group and wires the VMs at this host instead. Pair with enable_managed_redis = false."
  type        = string
  default     = null
}

variable "redis_endpoint_override_port" {
  description = "Port on the customer-managed Redis endpoint. Ignored unless redis_endpoint_override is set."
  type        = number
  default     = 6379
}

variable "redis_endpoint_override_tls" {
  description = "Whether the customer-managed Redis endpoint requires in-transit TLS. Ignored unless redis_endpoint_override is set."
  type        = bool
  default     = true
}


variable "enable_alb_deletion_protection" {
  description = "Enable deletion protection on the ALB. Default true; dev/test override to false to let `terraform destroy` succeed."
  type        = bool
  default     = true
}

variable "enable_alb_access_logging" {
  description = "Provision an S3 bucket for ALB access logs and enable the listener access_logs block."
  type        = bool
  default     = false
}

variable "alb_access_log_retention_days" {
  description = "Days to retain ALB access log objects."
  type        = number
  default     = 365
}


# ----- RDS production-hardening (opt-in) -----

variable "rds_enhanced_monitoring_interval" {
  description = "RDS enhanced monitoring sample interval. 0 disables. CKV_AWS_118."
  type        = number
  default     = 0
}

variable "rds_enabled_cloudwatch_log_types" {
  description = "RDS log types to export to CloudWatch. CKV_AWS_129."
  type        = list(string)
  default     = []
}

variable "rds_iam_authentication_enabled" {
  description = "Enable IAM DB authentication. CKV_AWS_161."
  type        = bool
  default     = false
}

variable "rds_performance_insights_enabled" {
  description = "Enable RDS Performance Insights. CKV_AWS_354."
  type        = bool
  default     = false
}

variable "rds_performance_insights_retention_days" {
  description = "Performance Insights retention. 7 = free tier; 731 = long-term."
  type        = number
  default     = 7
}

variable "tags" {
  type    = map(string)
  default = {}
}
