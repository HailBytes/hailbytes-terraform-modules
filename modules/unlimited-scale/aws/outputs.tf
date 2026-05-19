output "alb_dns_name" { value = aws_lb.main.dns_name }
output "alb_zone_id" { value = aws_lb.main.zone_id }
output "alb_arn" { value = aws_lb.main.arn }

output "autoscaling_group_name" { value = aws_autoscaling_group.main.name }
output "autoscaling_group_arn" { value = aws_autoscaling_group.main.arn }
output "launch_template_id" { value = aws_launch_template.main.id }

output "db_endpoint" { value = aws_db_instance.primary.endpoint }
output "db_read_endpoints" { value = aws_db_instance.replica[*].endpoint }
output "db_secret_arn" { value = aws_secretsmanager_secret.db.arn }

output "sns_alerts_topic_arn" { value = aws_sns_topic.alerts.arn }
output "ami_id" { value = data.aws_ami.hailbytes.id }
output "alb_access_logs_bucket" { value = aws_s3_bucket.alb_logs.id }

# ----- Patching and migration safety -----

output "backup_bucket_name" {
  description = "Name of the S3 bucket configured to receive pre-patch bundles. Empty if neither create_backup_bucket nor backup_bucket_name is set."
  value       = local.effective_backup_bucket
}

output "backup_s3_uri_prefix" {
  description = "Fully-qualified S3 URI prefix that the on-VM ha-pre-patch-backup.sh and /api/instance/export upload bundles to. Empty if no backup bucket is configured."
  value       = local.effective_backup_bucket == null ? "" : "s3://${local.effective_backup_bucket}/${local.backup_object_prefix}"
}

output "pre_patch_ssm_document_name" {
  description = "Name of the AWS Systems Manager Run Command document that triggers a pre-patch backup + RDS snapshot. Run from the Console under Systems Manager -> Run Command -> select this document, target instances tagged hailbytes-sat=true."
  value       = aws_ssm_document.pre_patch_backup.name
}

output "post_patch_ssm_document_name" {
  description = "Name of the AWS Systems Manager Run Command document that runs the on-VM five-probe post-patch verifier (used by the autoscaling instance_refresh hooks)."
  value       = aws_ssm_document.post_patch_verify.name
}

output "schema_version_endpoint" {
  description = "HTTPS URL to GET for the running schema version. CI/CD post-patch verify scripts can curl this and compare against the expected version emitted by the AMI build."
  value       = "https://${aws_lb.main.dns_name}${var.schema_version_endpoint_path}"
}

output "redis_endpoint" {
  description = "Host:port of the Redis endpoint wired into the ASG launch template. Either the module-provisioned ElastiCache replication group or var.redis_endpoint_override."
  value       = local.effective_redis_host == null ? "" : "${local.effective_redis_host}:${local.effective_redis_port}"
}

output "redis_mode" {
  description = "How Redis is wired: 'managed' (this module provisioned ElastiCache), 'override' (customer-supplied), or 'disabled' (horizontal scaling will not be session-safe)."
  value       = local.provision_managed_redis ? "managed" : (var.redis_endpoint_override == null ? "disabled" : "override")
}

output "waf_attached" {
  description = "True when var.waf_web_acl_arn was set and a WAFv2 association exists for the ALB."
  value       = var.waf_web_acl_arn != null
}
