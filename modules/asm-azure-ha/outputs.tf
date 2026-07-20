# Outputs re-exported from modules/ha-hot-hot/azure.

output "load_balancer_public_ip" {
  description = "Public IP of the load balancer frontend (or App Gateway frontend when enable_application_gateway = true)."
  value       = module.this.load_balancer_public_ip
  sensitive   = false
}

output "load_balancer_id" {
  value     = module.this.load_balancer_id
  sensitive = false
}

output "vm_nsg_id" {
  description = "ID of the NSG filtering vm_subnet_id to 443/allowed_cidrs. Empty when vm_subnet_id == lb_subnet_id."
  value       = module.this.vm_nsg_id
  sensitive   = false
}

output "vm_ids" {
  description = "Resource IDs of the two active/active VMs."
  value       = module.this.vm_ids
  sensitive   = false
}

output "vm_private_ips" {
  value     = module.this.vm_private_ips
  sensitive = false
}

output "postgres_fqdn" {
  description = "DB endpoint. Flexible Server FQDN in 'flexible_server' mode; private-IP:5432 of the self-managed Postgres VM in 'vm' mode."
  value       = module.this.postgres_fqdn
  sensitive   = false
}

output "key_vault_uri" {
  description = "Key Vault URI; the DB password is at secret name 'hailbytes-db-password'."
  value       = module.this.key_vault_uri
  sensitive   = false
}

# ----- Patching and migration safety -----

output "db_mode" {
  description = "Active DB mode: 'flexible_server' or 'vm'."
  value       = module.this.db_mode
  sensitive   = false
}

output "backup_storage_account_name" {
  description = "Name of the Storage Account configured to receive pre-patch bundles. Empty if neither create_backup_storage_account nor backup_storage_account_name is set."
  value       = module.this.backup_storage_account_name
  sensitive   = false
}

output "backup_container_uri" {
  description = "Fully-qualified URI prefix for backup bundles."
  value       = module.this.backup_container_uri
  sensitive   = false
}

output "pre_patch_run_command_name" {
  description = "Name of the Azure Run Command document that triggers a pre-patch backup + Flexible Server / disk snapshot."
  value       = module.this.pre_patch_run_command_name
  sensitive   = false
}

output "schema_version_endpoint" {
  description = "HTTPS URL that returns the running schema version. CI/CD post-patch verify scripts curl this."
  value       = module.this.schema_version_endpoint
  sensitive   = false
}

output "alerts_action_group_id" {
  description = "Action Group ID for patching tripwire alerts. Empty when alert_email is null."
  value       = module.this.alerts_action_group_id
  sensitive   = false
}

output "waf_attached" {
  description = "True when var.waf_policy_id was set on the App Gateway."
  value       = module.this.waf_attached
  sensitive   = false
}

output "application_gateway_id" {
  description = "ID of the Application Gateway when enable_application_gateway = true; empty otherwise."
  value       = module.this.application_gateway_id
  sensitive   = false
}

output "post_patch_run_command_name" {
  description = "Name of the Azure Run Command document that runs the on-VM five-probe post-patch verifier on each VM."
  value       = module.this.post_patch_run_command_name
  sensitive   = false
}

output "redis_endpoint" {
  description = "Host:port of the Redis endpoint wired into the HA VMs. Either the module-provisioned Azure Cache for Redis or var.redis_endpoint_override."
  value       = module.this.redis_endpoint
  sensitive   = false
}

output "redis_mode" {
  description = "How Redis is wired: 'managed' (this module provisioned Azure Cache), 'override' (customer-supplied endpoint), or 'disabled' (HA is not actually safe)."
  value       = module.this.redis_mode
  sensitive   = false
}
