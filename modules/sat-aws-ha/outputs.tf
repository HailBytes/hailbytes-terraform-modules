# Outputs re-exported from modules/ha-hot-hot/aws.

output "alb_dns_name" {
  description = "Public DNS name of the ALB. Point your CNAME / Route53 alias here."
  value       = module.this.alb_dns_name
  sensitive   = false
}

output "alb_zone_id" {
  description = "Hosted zone ID of the ALB, for Route 53 alias records."
  value       = module.this.alb_zone_id
  sensitive   = false
}

output "alb_arn" {
  value     = module.this.alb_arn
  sensitive = false
}

output "instance_ids" {
  description = "EC2 instance IDs of the two active/active VMs."
  value       = module.this.instance_ids
  sensitive   = false
}

output "db_endpoint" {
  description = "DB endpoint (host:port). In RDS mode this is the RDS endpoint; in EC2 mode it's <private-ip>:5432. Connection details are in Secrets Manager."
  value       = module.this.db_endpoint
  sensitive   = false
}

output "db_secret_arn" {
  description = "Secrets Manager ARN containing Postgres credentials."
  value       = module.this.db_secret_arn
  sensitive   = false
}

output "db_instance_arn" {
  description = "ARN of the DB resource — RDS instance in 'rds' mode, EC2 instance in 'ec2' mode."
  value       = module.this.db_instance_arn
  sensitive   = false
}

output "ami_id" {
  value     = module.this.ami_id
  sensitive = false
}

output "security_group_ids" {
  value     = module.this.security_group_ids
  sensitive = false
}

# ----- Patching and migration safety -----

output "db_mode" {
  description = "Active DB mode: 'rds' or 'ec2'."
  value       = module.this.db_mode
  sensitive   = false
}

output "backup_bucket_name" {
  description = "Name of the S3 bucket configured to receive pre-patch bundles. Empty if neither create_backup_bucket nor backup_bucket_name is set."
  value       = module.this.backup_bucket_name
  sensitive   = false
}

output "backup_s3_uri_prefix" {
  description = "Fully-qualified S3 URI prefix that the on-VM ha-pre-patch-backup.sh and /api/instance/export upload bundles to."
  value       = module.this.backup_s3_uri_prefix
  sensitive   = false
}

output "pre_patch_ssm_document_name" {
  description = "Name of the AWS Systems Manager Run Command document that triggers a pre-patch backup + DB snapshot."
  value       = module.this.pre_patch_ssm_document_name
  sensitive   = false
}

output "schema_version_endpoint" {
  description = "HTTPS URL that returns the running schema version. Used by post-patch verify scripts."
  value       = module.this.schema_version_endpoint
  sensitive   = false
}

output "alerts_topic_arn" {
  description = "SNS topic ARN for the patching tripwire alarms."
  value       = module.this.alerts_topic_arn
  sensitive   = false
}

output "waf_attached" {
  description = "True when var.waf_web_acl_arn was set and a WAFv2 association exists for the ALB."
  value       = module.this.waf_attached
  sensitive   = false
}

output "post_patch_ssm_document_name" {
  description = "Name of the AWS Systems Manager Run Command document that runs the on-VM five-probe post-patch verifier."
  value       = module.this.post_patch_ssm_document_name
  sensitive   = false
}

output "redis_endpoint" {
  description = "Host:port of the Redis endpoint wired into the HA VMs. Either the module-provisioned ElastiCache replication group or var.redis_endpoint_override."
  value       = module.this.redis_endpoint
  sensitive   = false
}

output "redis_mode" {
  description = "How Redis is wired: 'managed' (this module provisioned ElastiCache), 'override' (customer-supplied endpoint), or 'disabled' (HA is not actually safe)."
  value       = module.this.redis_mode
  sensitive   = false
}
