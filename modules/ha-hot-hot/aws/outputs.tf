output "alb_dns_name" {
  description = "Public DNS name of the ALB. Point your CNAME / Route53 alias here."
  value       = aws_lb.main.dns_name
}

output "alb_zone_id" {
  description = "Hosted zone ID of the ALB, for Route 53 alias records."
  value       = aws_lb.main.zone_id
}

output "alb_arn" {
  description = "ARN of the Application Load Balancer. Use for attaching WAF web ACLs, Lambda triggers, or cross-account resource policies."
  value       = aws_lb.main.arn
}

output "instance_ids" {
  description = "EC2 instance IDs of the two active/active VMs."
  value       = aws_instance.vm[*].id
}

output "db_endpoint" {
  description = "DB endpoint (host:port). In RDS mode this is the RDS endpoint; in EC2 mode it's <private-ip>:5432. Connection details are in Secrets Manager."
  value       = "${local.db_host}:${local.db_port}"
}

output "db_secret_arn" {
  description = "Secrets Manager ARN containing Postgres credentials."
  value       = aws_secretsmanager_secret.db.arn
}

output "db_instance_arn" {
  description = "ARN of the DB resource — RDS instance in 'rds' mode, EC2 instance in 'ec2' mode."
  value       = local.db_arn
}

output "db_mode" {
  description = "Active DB mode: 'rds', 'ec2', or 'external'."
  value       = var.db_mode
}

# ----- Patching and migration safety -----

output "backup_bucket_name" {
  description = "Name of the S3 bucket configured to receive pre-patch bundles. Empty if neither create_backup_bucket nor backup_bucket_name is set."
  value       = local.effective_backup_bucket
}

output "backup_s3_uri_prefix" {
  description = "Fully-qualified S3 URI prefix that the on-VM ha-pre-patch-backup.sh and /api/instance/export upload bundles to."
  value       = local.effective_backup_bucket == null ? "" : "s3://${local.effective_backup_bucket}/${local.backup_object_prefix}"
}

output "pre_patch_ssm_document_name" {
  description = "Name of the AWS Systems Manager Run Command document that triggers a pre-patch backup + DB snapshot."
  value       = aws_ssm_document.pre_patch_backup.name
}

output "post_patch_ssm_document_name" {
  description = "Name of the AWS Systems Manager Run Command document that runs the on-VM five-probe post-patch verifier."
  value       = aws_ssm_document.post_patch_verify.name
}

output "schema_version_endpoint" {
  description = "HTTPS URL that returns the running schema version. Used by post-patch verify scripts."
  value       = "https://${aws_lb.main.dns_name}${var.schema_version_endpoint_path}"
}

output "alerts_topic_arn" {
  description = "SNS topic ARN for the patching tripwire alarms."
  value       = aws_sns_topic.alerts.arn
}

output "waf_attached" {
  description = "True when var.waf_web_acl_arn was set and a WAFv2 association exists for the ALB."
  value       = var.waf_web_acl_arn != null
}

output "ami_id" {
  description = "AMI ID resolved from the HailBytes Marketplace image for this product and version. Useful for audit logging and drift detection."
  value       = data.aws_ami.hailbytes.id
}

output "security_group_ids" {
  description = "Map of security group IDs keyed by role: alb, vm, db, redis. The redis key is null when Redis is not managed by this module."
  value = {
    alb   = aws_security_group.alb.id
    vm    = aws_security_group.vm.id
    db    = aws_security_group.db.id
    redis = local.provision_managed_redis ? aws_security_group.redis[0].id : null
  }
}

output "redis_endpoint" {
  description = "Host:port of the Redis endpoint wired into the HA VMs. Either the module-provisioned ElastiCache replication group or var.redis_endpoint_override."
  value       = local.effective_redis_host == null ? "" : "${local.effective_redis_host}:${local.effective_redis_port}"
}

output "redis_mode" {
  description = "How Redis is wired: 'managed' (this module provisioned ElastiCache), 'override' (customer-supplied endpoint), or 'disabled' (HA is not actually safe)."
  value       = local.provision_managed_redis ? "managed" : (var.redis_endpoint_override == null ? "disabled" : "override")
}

output "flow_log_group_name" {
  description = "CloudWatch log group name receiving VPC Flow Logs. Empty string when enable_flow_logs is false."
  value       = var.enable_flow_logs ? aws_cloudwatch_log_group.flow_logs[0].name : ""
}

output "db_is_customer_managed" {
  description = "True when db_mode = 'external'. When true, HailBytes provisions no database: availability, backups, patching and point-in-time restore are the customer's responsibility, and the pre-patch SSM document takes no server-side snapshot."
  value       = local.use_external_db
}

# Operators need this to log in for the first time. The Azure module surfaces
# its Key Vault URI; the AWS equivalent is the secret ARN, and leaving it
# undiscoverable meant falling back to the serial console -- which on a pair
# shows one node's guess at a password the other node may have overwritten.
output "initial_admin_password_secret_arn" {
  description = "Secrets Manager ARN holding the shared initial admin password. Read it with: aws secretsmanager get-secret-value --secret-id <arn> --query SecretString --output text"
  value       = aws_secretsmanager_secret.admin_initial_password.arn
}

output "session_keys_secret_arn" {
  description = "Secrets Manager ARN holding the shared session HMAC and encryption keys. Both nodes read this; rotating it invalidates every live session."
  value       = aws_secretsmanager_secret.session_keys.arn
}
