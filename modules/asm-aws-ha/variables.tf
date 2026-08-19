# Variables for ASM on AWS (ha)
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
  description = "EC2 instance type for the HailBytes application node(s). Constrained to the portable m6i ladder; see the validation message. Defaults to the 8-vCore training floor."
  type        = string
  default     = "m6i.2xlarge"

  validation {
    # The portable ladder. Every entry is a stock m6i general-purpose shape at
    # the same 4 GB-per-vCore ratio as the Azure Dsv5 equivalent, so a
    # deployment can move between clouds without changing tier.
    condition = contains([
      "m6i.large",    # 2 vCPU  - phishing simulation only
      "m6i.xlarge",   # 4 vCPU  - phishing simulation only
      "m6i.2xlarge",  # 8 vCPU  - training floor and purchasable entry rung
      "m6i.4xlarge",  # 16 vCPU
      "m6i.8xlarge",  # 32 vCPU
      "m6i.12xlarge", # 48 vCPU
      "m6i.16xlarge", # 64 vCPU
    ], var.instance_type)
    error_message = "instance_type must be a portable HailBytes rung: m6i.large (2 vCPU), m6i.xlarge (4), m6i.2xlarge (8), m6i.4xlarge (16), m6i.8xlarge (32), m6i.12xlarge (48), m6i.16xlarge (64). AWS m6i has NO general-purpose size between 16 and 32 vCPU, so a 24-vCore deployment cannot be delivered as one VM or as a symmetric pair (2 x 12 does not exist either) -- quote 16 or 32. The 2 and 4 vCPU rungs are for phishing-simulation-only instances: anything serving training content or running the recurring automations carries an 8-vCore floor."
  }
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
  description = "Deprecated alias for rds_backup_retention_period. When set (non-null), this value wins over rds_backup_retention_period. Leave null and use rds_backup_retention_period instead. Kept for backward compatibility with pre-patching-safety configs."
  type        = number
  default     = null
}

variable "db_deletion_protection" {
  description = "Governs db_mode = \"rds\" only: sets the RDS instance's deletion_protection, disables skip_final_snapshot, and takes a final snapshot on destroy. Has no effect when db_mode = \"ec2\" — that path's data volume always has prevent_destroy = true regardless of this variable, since EBS has no snapshot-on-destroy equivalent to fall back on."
  type        = bool
  default     = true
}

variable "enable_customer_managed_key" {
  type    = bool
  default = false
}

variable "enable_flow_logs" {
  description = "Enable VPC Flow Logs for the provided VPC, sending ALL traffic to a CloudWatch log group named /aws/vpc-flow-logs/<name_prefix>. Matches the default stated in SECURITY-DEFAULTS.md."
  type        = bool
  default     = true
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
  description = "Database backend. 'rds' (default) provisions a Multi-AZ RDS instance — recommended for production. 'ec2' provisions a third EC2 with self-managed Postgres 16 for customers that must keep data plane on EC2. Matches HAILBYTES_DB_MODE used by the Cloud Shell deploy scripts."
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
  description = "Days RDS retains automated daily backups. 7 satisfies the procurement-grade baseline; raise for longer point-in-time-restore windows."
  type        = number
  default     = 7
}

variable "rds_copy_tags_to_snapshot" {
  description = "Propagate tags from the RDS instance to automated and on-demand snapshots."
  type        = bool
  default     = true
}

variable "create_backup_bucket" {
  description = "Provision an S3 bucket (versioning + object-lock governance + lifecycle to IA at 30d and Deep Archive at 90d) for pre-patch /api/instance/export bundles. The SAT instance profile gets least-privilege PutObject on hailbytes-*.tar.gz."
  type        = bool
  default     = true
}

variable "backup_bucket_name" {
  description = "Name of an existing S3 bucket to use for pre-patch backups. If null and create_backup_bucket is true, the module names one '<name_prefix>-backups-<account_id>'. If non-null and create_backup_bucket is false, the module only attaches the IAM PutObject policy."
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
  description = "Target-group 5xx rate (percent) that trips the patching alarm. Default 1% over 2 evaluation periods of 1 minute."
  type        = number
  default     = 1
}

variable "waf_web_acl_arn" {
  description = "Optional ARN of an existing WAFv2 web ACL to associate with the ALB. Defaults to null (not attached). HailBytes does not bundle a managed ruleset."
  type        = string
  default     = null
}

variable "alert_email" {
  description = "Email subscribed to the patching alarm SNS topic. Pass null to skip."
  type        = string
  default     = null
}

variable "schema_version_endpoint_path" {
  description = "Path on the SAT/ASM API that returns the running schema version."
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
  description = "Host of a customer-managed Redis endpoint (e.g. existing ElastiCache, MemoryDB, or self-managed Redis Sentinel). When non-null, the module skips its own ElastiCache replication group and wires the VMs at this host instead. Pair with enable_managed_redis = false."
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
  description = "Enable deletion protection on the ALB. Default true; production deployments should keep this on. Set to false in dev/test sandboxes where you want `terraform destroy` to succeed without manual cleanup."
  type        = bool
  default     = true
}

variable "enable_alb_access_logging" {
  description = "Provision an S3 bucket for ALB access logs and enable the listener access_logs block. Adds ~$1-5/mo storage cost depending on traffic; recommended for production deployments where the access log is part of the audit trail."
  type        = bool
  default     = false
}

variable "alb_access_log_retention_days" {
  description = "Days to retain ALB access log objects before lifecycle expiration. Default 365 (one calendar year) — long enough for most compliance lookback windows."
  type        = number
  default     = 365
}


# ----- RDS production-hardening (opt-in) -----

variable "rds_enhanced_monitoring_interval" {
  description = "RDS enhanced monitoring sample interval in seconds (0, 1, 5, 10, 15, 30, 60). 0 disables enhanced monitoring. Default 0; production deployments typically set 60. CKV_AWS_118."
  type        = number
  default     = 0
}

variable "rds_enabled_cloudwatch_log_types" {
  description = "RDS log types to export to CloudWatch. Empty list = no log exports (cost-saving default). Production should set to [\"postgresql\", \"upgrade\"]. CKV_AWS_129."
  type        = list(string)
  default     = []
}

variable "rds_iam_authentication_enabled" {
  description = "Enable IAM database authentication on the RDS instance. Adds app-side complexity (psql connections must mint IAM tokens) but eliminates long-lived passwords. CKV_AWS_161."
  type        = bool
  default     = false
}

variable "rds_performance_insights_enabled" {
  description = "Enable RDS Performance Insights. Adds ~$0/instance for 7-day retention (free tier); KMS-encrypted automatically when enable_customer_managed_key is also set. CKV_AWS_354."
  type        = bool
  default     = false
}

variable "rds_performance_insights_retention_days" {
  description = "Performance Insights data retention. 7 = free tier (default); 731 = long-term retention (paid)."
  type        = number
  default     = 7
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "admin_port" {
  description = "Port the HailBytes admin server listens on. Used by the post-patch verifier, which probes the instance over localhost."
  type        = number
  default     = 3333
}

variable "external_db_host" {
  description = "Hostname or private IP of a customer-operated PostgreSQL server. Required when db_mode = \"external\", ignored otherwise. Must be resolvable and reachable from the private subnets."
  type        = string
  default     = null
}

variable "external_db_port" {
  description = "Port of the customer-operated PostgreSQL server."
  type        = number
  default     = 5432
}

variable "external_db_name" {
  description = "Database name on the customer-operated server. It must already exist; the module does not create it."
  type        = string
  default     = "hailbytes"
}

variable "external_db_username" {
  description = "Role the application connects as. It needs full DDL rights on external_db_name — the binary runs goose migrations at boot."
  type        = string
  default     = "hailbytes"
}

variable "external_db_password" {
  description = "Password for external_db_username. Required when db_mode = \"external\". Written to the deployment's Secrets Manager secret; supply it through a tfvars file or TF_VAR_ environment variable, never a literal in version control."
  type        = string
  default     = null
  sensitive   = true
}

variable "external_db_sslmode" {
  description = "libpq sslmode for the connection to the customer-operated server. 'require' is the minimum accepted; 'verify-full' is recommended."
  type        = string
  default     = "require"
}

variable "health_check_path" {
  description = "Override the load-balancer health probe path. Leave null to use the product default: /api/health for SAT, /api/ready for ASM. Both are unauthenticated and return non-200 when the database is unreachable."
  type        = string
  default     = null
}
