output "instance_id" {
  description = "EC2 instance ID."
  value       = aws_instance.vm.id
}

output "instance_arn" {
  description = "EC2 instance ARN."
  value       = aws_instance.vm.arn
}

output "private_ip" {
  description = "Private IPv4 of the VM."
  value       = aws_instance.vm.private_ip
}

output "public_ip" {
  description = "Public IPv4 of the VM, or null if associate_public_ip is false."
  value       = aws_instance.vm.public_ip
}

output "security_group_id" {
  description = "Security group attached to the VM."
  value       = aws_security_group.vm.id
}

output "iam_role_arn" {
  description = "IAM role attached to the VM."
  value       = aws_iam_role.vm.arn
}

output "ami_id" {
  description = "Resolved AMI ID for the HailBytes Marketplace image. If empty, the marketplace subscription is missing."
  value       = data.aws_ami.hailbytes.id
}

output "data_volume_id" {
  description = "EBS volume ID for the data volume."
  value       = aws_ebs_volume.data.id
}

output "console_url" {
  description = "AWS console URL for this instance."
  value       = "https://console.aws.amazon.com/ec2/home#InstanceDetails:instanceId=${aws_instance.vm.id}"
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
  description = "Name of the AWS Systems Manager Run Command document that triggers a pre-patch backup + EBS data-volume snapshot. Run from the Console under Systems Manager -> Run Command, targeting instances tagged hailbytes-<product>=true."
  value       = aws_ssm_document.pre_patch_backup.name
}

output "flow_log_group_name" {
  description = "CloudWatch log group name receiving VPC Flow Logs. Empty string when enable_flow_logs is false."
  value       = var.enable_flow_logs ? aws_cloudwatch_log_group.flow_logs[0].name : ""
}
