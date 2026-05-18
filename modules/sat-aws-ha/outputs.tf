# Outputs re-exported from modules/ha-hot-hot/aws.

output "alb_dns_name" {
  value     = module.this.alb_dns_name
  sensitive = false
}

output "alb_zone_id" {
  value     = module.this.alb_zone_id
  sensitive = false
}

output "alb_arn" {
  value     = module.this.alb_arn
  sensitive = false
}

output "instance_ids" {
  value     = module.this.instance_ids
  sensitive = false
}

output "db_endpoint" {
  value     = module.this.db_endpoint
  sensitive = false
}

output "db_secret_arn" {
  value     = module.this.db_secret_arn
  sensitive = false
}

output "db_instance_arn" {
  value     = module.this.db_instance_arn
  sensitive = false
}

output "ami_id" {
  value     = module.this.ami_id
  sensitive = false
}

output "security_group_ids" {
  value     = module.this.security_group_ids
  sensitive = false
}
