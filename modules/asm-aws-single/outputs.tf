# Outputs re-exported from modules/single-vm/aws.

output "instance_id" {
  description = "EC2 instance ID."
  value       = module.this.instance_id
  sensitive   = false
}

output "instance_arn" {
  description = "EC2 instance ARN."
  value       = module.this.instance_arn
  sensitive   = false
}

output "private_ip" {
  description = "Private IPv4 of the VM."
  value       = module.this.private_ip
  sensitive   = false
}

output "public_ip" {
  description = "Public IPv4 of the VM, or null if associate_public_ip is false."
  value       = module.this.public_ip
  sensitive   = false
}

output "security_group_id" {
  description = "Security group attached to the VM."
  value       = module.this.security_group_id
  sensitive   = false
}

output "iam_role_arn" {
  description = "IAM role attached to the VM."
  value       = module.this.iam_role_arn
  sensitive   = false
}

output "ami_id" {
  description = "Resolved AMI ID for the HailBytes Marketplace image. If empty, the marketplace subscription is missing."
  value       = module.this.ami_id
  sensitive   = false
}

output "data_volume_id" {
  description = "EBS volume ID for the data volume."
  value       = module.this.data_volume_id
  sensitive   = false
}

output "console_url" {
  description = "AWS console URL for this instance."
  value       = module.this.console_url
  sensitive   = false
}

# ----- Patching and migration safety -----

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
  description = "Name of the AWS Systems Manager Run Command document that triggers a pre-patch backup + EBS data-volume snapshot. Run from the Console under Systems Manager -> Run Command, targeting instances tagged hailbytes-<product>=true."
  value       = module.this.pre_patch_ssm_document_name
  sensitive   = false
}
