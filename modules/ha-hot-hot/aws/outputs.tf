output "alb_dns_name" {
  description = "Public DNS name of the ALB. Point your CNAME / Route53 alias here."
  value       = aws_lb.main.dns_name
}

output "alb_zone_id" {
  description = "Hosted zone ID of the ALB, for Route 53 alias records."
  value       = aws_lb.main.zone_id
}

output "alb_arn" {
  value = aws_lb.main.arn
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
  description = "Active DB mode: 'rds' or 'ec2'."
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
  value = data.aws_ami.hailbytes.id
}

output "security_group_ids" {
  value = {
    alb = aws_security_group.alb.id
    vm  = aws_security_group.vm.id
    db  = aws_security_group.db.id
  }
}
