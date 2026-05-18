# Outputs re-exported from modules/unlimited-scale/aws.

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

output "autoscaling_group_name" {
  value     = module.this.autoscaling_group_name
  sensitive = false
}

output "autoscaling_group_arn" {
  value     = module.this.autoscaling_group_arn
  sensitive = false
}

output "launch_template_id" {
  value     = module.this.launch_template_id
  sensitive = false
}

output "db_endpoint" {
  value     = module.this.db_endpoint
  sensitive = false
}

output "db_read_endpoints" {
  value     = module.this.db_read_endpoints
  sensitive = false
}

output "db_secret_arn" {
  value     = module.this.db_secret_arn
  sensitive = false
}

output "sns_alerts_topic_arn" {
  value     = module.this.sns_alerts_topic_arn
  sensitive = false
}

output "ami_id" {
  value     = module.this.ami_id
  sensitive = false
}

output "alb_access_logs_bucket" {
  value     = module.this.alb_access_logs_bucket
  sensitive = false
}
