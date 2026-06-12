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

# ----- Patching and migration safety -----

output "db_mode" {
  value     = module.this.db_mode
  sensitive = false
}

output "backup_bucket_name" {
  value     = module.this.backup_bucket_name
  sensitive = false
}

output "backup_s3_uri_prefix" {
  value     = module.this.backup_s3_uri_prefix
  sensitive = false
}

output "pre_patch_ssm_document_name" {
  value     = module.this.pre_patch_ssm_document_name
  sensitive = false
}

output "schema_version_endpoint" {
  value     = module.this.schema_version_endpoint
  sensitive = false
}

output "alerts_topic_arn" {
  value     = module.this.alerts_topic_arn
  sensitive = false
}

output "waf_attached" {
  value     = module.this.waf_attached
  sensitive = false
}

output "post_patch_ssm_document_name" {
  value     = module.this.post_patch_ssm_document_name
  sensitive = false
}

output "redis_endpoint" {
  value     = module.this.redis_endpoint
  sensitive = false
}

output "redis_mode" {
  value     = module.this.redis_mode
  sensitive = false
}
