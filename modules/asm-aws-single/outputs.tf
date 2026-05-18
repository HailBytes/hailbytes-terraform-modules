# Outputs re-exported from modules/single-vm/aws.

output "instance_id" {
  value     = module.this.instance_id
  sensitive = false
}

output "instance_arn" {
  value     = module.this.instance_arn
  sensitive = false
}

output "private_ip" {
  value     = module.this.private_ip
  sensitive = false
}

output "public_ip" {
  value     = module.this.public_ip
  sensitive = false
}

output "security_group_id" {
  value     = module.this.security_group_id
  sensitive = false
}

output "iam_role_arn" {
  value     = module.this.iam_role_arn
  sensitive = false
}

output "ami_id" {
  value     = module.this.ami_id
  sensitive = false
}

output "data_volume_id" {
  value     = module.this.data_volume_id
  sensitive = false
}

output "console_url" {
  value     = module.this.console_url
  sensitive = false
}
