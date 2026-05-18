# Outputs re-exported from modules/unlimited-scale/azure.

output "load_balancer_public_ip" {
  value     = module.this.load_balancer_public_ip
  sensitive = false
}

output "vmss_id" {
  value     = module.this.vmss_id
  sensitive = false
}

output "vmss_name" {
  value     = module.this.vmss_name
  sensitive = false
}

output "postgres_primary_fqdn" {
  value     = module.this.postgres_primary_fqdn
  sensitive = false
}

output "postgres_replica_fqdns" {
  value     = module.this.postgres_replica_fqdns
  sensitive = false
}

output "key_vault_uri" {
  value     = module.this.key_vault_uri
  sensitive = false
}

output "action_group_id" {
  value     = module.this.action_group_id
  sensitive = false
}

# ----- Patching and migration safety -----

output "backup_storage_account_name" {
  value     = module.this.backup_storage_account_name
  sensitive = false
}

output "backup_container_uri" {
  value     = module.this.backup_container_uri
  sensitive = false
}

output "pre_patch_run_command_extension_name" {
  value     = module.this.pre_patch_run_command_extension_name
  sensitive = false
}

output "schema_version_endpoint" {
  value     = module.this.schema_version_endpoint
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
