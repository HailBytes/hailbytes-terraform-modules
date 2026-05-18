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
