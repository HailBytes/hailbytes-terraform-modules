# Outputs re-exported from modules/ha-hot-hot/azure.

output "load_balancer_public_ip" {
  value     = module.this.load_balancer_public_ip
  sensitive = false
}

output "load_balancer_id" {
  value     = module.this.load_balancer_id
  sensitive = false
}

output "vm_ids" {
  value     = module.this.vm_ids
  sensitive = false
}

output "vm_private_ips" {
  value     = module.this.vm_private_ips
  sensitive = false
}

output "postgres_fqdn" {
  value     = module.this.postgres_fqdn
  sensitive = false
}

output "key_vault_uri" {
  value     = module.this.key_vault_uri
  sensitive = false
}

# ----- Patching and migration safety -----

output "db_mode" {
  value     = module.this.db_mode
  sensitive = false
}

output "backup_storage_account_name" {
  value     = module.this.backup_storage_account_name
  sensitive = false
}

output "backup_container_uri" {
  value     = module.this.backup_container_uri
  sensitive = false
}

output "pre_patch_run_command_name" {
  value     = module.this.pre_patch_run_command_name
  sensitive = false
}

output "schema_version_endpoint" {
  value     = module.this.schema_version_endpoint
  sensitive = false
}

output "alerts_action_group_id" {
  value     = module.this.alerts_action_group_id
  sensitive = false
}

output "waf_attached" {
  value     = module.this.waf_attached
  sensitive = false
}

output "application_gateway_id" {
  value     = module.this.application_gateway_id
  sensitive = false
}

output "post_patch_run_command_name" {
  value     = module.this.post_patch_run_command_name
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
