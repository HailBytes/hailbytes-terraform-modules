# Outputs re-exported from modules/unlimited-scale/aws.

output "alb_dns_name" {
  description = "Public DNS name of the ALB. Point your CNAME / Route 53 alias here."
  value       = module.this.alb_dns_name
  sensitive   = false
}

output "alb_zone_id" {
  description = "Hosted zone ID of the ALB, for Route 53 alias records."
  value       = module.this.alb_zone_id
  sensitive   = false
}

output "alb_arn" {
  description = "ARN of the Application Load Balancer."
  value       = module.this.alb_arn
  sensitive   = false
}

output "autoscaling_group_name" {
  description = "Name of the Auto Scaling Group."
  value       = module.this.autoscaling_group_name
  sensitive   = false
}

output "autoscaling_group_arn" {
  description = "ARN of the Auto Scaling Group."
  value       = module.this.autoscaling_group_arn
  sensitive   = false
}

output "launch_template_id" {
  description = "ID of the EC2 launch template used by the ASG."
  value       = module.this.launch_template_id
  sensitive   = false
}

output "db_endpoint" {
  description = "RDS primary instance endpoint (host:port). Connection credentials are in Secrets Manager."
  value       = module.this.db_endpoint
  sensitive   = false
}

output "db_read_endpoints" {
  description = "List of RDS read replica endpoints (host:port), one per replica. Empty when db_read_replica_count is 0."
  value       = module.this.db_read_endpoints
  sensitive   = false
}

output "db_secret_arn" {
  description = "Secrets Manager ARN containing the RDS Postgres credentials."
  value       = module.this.db_secret_arn
  sensitive   = false
}

output "sns_alerts_topic_arn" {
  description = "ARN of the SNS topic receiving CloudWatch alarm notifications."
  value       = module.this.sns_alerts_topic_arn
  sensitive   = false
}

output "ami_id" {
  description = "ID of the HailBytes marketplace AMI resolved at plan time."
  value       = module.this.ami_id
  sensitive   = false
}

output "alb_access_logs_bucket" {
  description = "S3 bucket ID receiving ALB access logs."
  value       = module.this.alb_access_logs_bucket
  sensitive   = false
}

# ----- Patching and migration safety -----

output "backup_bucket_name" {
  description = "Name of the S3 bucket configured to receive pre-patch bundles. Empty if neither create_backup_bucket nor backup_bucket_name is set."
  value       = module.this.backup_bucket_name
  sensitive   = false
}

output "backup_s3_uri_prefix" {
  description = "Fully-qualified S3 URI prefix that the on-VM ha-pre-patch-backup.sh and /api/instance/export upload bundles to. Empty if no backup bucket is configured."
  value       = module.this.backup_s3_uri_prefix
  sensitive   = false
}

output "pre_patch_ssm_document_name" {
  description = "Name of the AWS Systems Manager Run Command document that triggers a pre-patch backup + RDS snapshot. Run from the Console under Systems Manager -> Run Command -> select this document, target instances tagged hailbytes-sat=true."
  value       = module.this.pre_patch_ssm_document_name
  sensitive   = false
}

output "schema_version_endpoint" {
  description = "HTTPS URL to GET for the running schema version. CI/CD post-patch verify scripts can curl this and compare against the expected version emitted by the AMI build."
  value       = module.this.schema_version_endpoint
  sensitive   = false
}

output "waf_attached" {
  description = "True when var.waf_web_acl_arn was set and a WAFv2 association exists for the ALB."
  value       = module.this.waf_attached
  sensitive   = false
}

output "post_patch_ssm_document_name" {
  description = "Name of the AWS Systems Manager Run Command document that runs the on-VM five-probe post-patch verifier (used by the autoscaling instance_refresh hooks)."
  value       = module.this.post_patch_ssm_document_name
  sensitive   = false
}

output "redis_endpoint" {
  description = "Host:port of the Redis endpoint wired into the ASG launch template. Either the module-provisioned ElastiCache replication group or var.redis_endpoint_override."
  value       = module.this.redis_endpoint
  sensitive   = false
}

output "redis_mode" {
  description = "How Redis is wired: 'managed' (this module provisioned ElastiCache), 'override' (customer-supplied), or 'disabled' (horizontal scaling will not be session-safe)."
  value       = module.this.redis_mode
  sensitive   = false
}
