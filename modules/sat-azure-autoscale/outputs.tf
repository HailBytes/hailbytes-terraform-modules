# Outputs re-exported from modules/unlimited-scale/azure.

output "load_balancer_public_ip" {
  description = "Public IP fronting the deployment. App Gateway IP when enable_application_gateway = true; Standard LB IP otherwise."
  value       = module.this.load_balancer_public_ip
  sensitive   = false
}

output "vmss_id" {
  description = "Resource ID of the Virtual Machine Scale Set."
  value       = module.this.vmss_id
  sensitive   = false
}

output "vmss_name" {
  description = "Name of the Virtual Machine Scale Set."
  value       = module.this.vmss_name
  sensitive   = false
}

output "postgres_primary_fqdn" {
  description = "FQDN of the primary Azure PostgreSQL Flexible Server."
  value       = module.this.postgres_primary_fqdn
  sensitive   = false
}

output "postgres_replica_fqdns" {
  description = "List of FQDNs for all PostgreSQL read replicas. Empty when postgres_replica_count is 0."
  value       = module.this.postgres_replica_fqdns
  sensitive   = false
}

output "key_vault_uri" {
  description = "URI of the Key Vault storing secrets and encryption keys."
  value       = module.this.key_vault_uri
  sensitive   = false
}

output "action_group_id" {
  description = "Resource ID of the Azure Monitor action group for alert notifications."
  value       = module.this.action_group_id
  sensitive   = false
}

# ----- Patching and migration safety -----

output "backup_storage_account_name" {
  description = "Name of the Storage Account configured to receive pre-patch bundles."
  value       = module.this.backup_storage_account_name
  sensitive   = false
}

output "backup_container_uri" {
  description = "Fully-qualified URI prefix for backup bundles."
  value       = module.this.backup_container_uri
  sensitive   = false
}

output "pre_patch_run_command_extension_name" {
  description = "Name of the VMSS extension wrapping the pre-patch backup. Invoke via `az vmss run-command`."
  value       = module.this.pre_patch_run_command_extension_name
  sensitive   = false
}

output "schema_version_endpoint" {
  description = "HTTPS URL that returns the running schema version."
  value       = module.this.schema_version_endpoint
  sensitive   = false
}

output "waf_attached" {
  description = "True when var.waf_policy_id is set and an App Gateway is enabled."
  value       = module.this.waf_attached
  sensitive   = false
}

output "application_gateway_id" {
  description = "ID of the Application Gateway when enable_application_gateway = true; empty otherwise."
  value       = module.this.application_gateway_id
  sensitive   = false
}

output "post_patch_run_command_extension_name" {
  description = "Name of the VMSS extension wrapping the post-patch verifier. Invoke via `az vmss run-command`."
  value       = module.this.post_patch_run_command_extension_name
  sensitive   = false
}

output "redis_endpoint" {
  description = "Host:port of the Redis endpoint wired into the VMSS launch profile. Either the module-provisioned Azure Cache or var.redis_endpoint_override."
  value       = module.this.redis_endpoint
  sensitive   = false
}

output "redis_mode" {
  description = "How Redis is wired: 'managed' (this module provisioned Azure Cache), 'override' (customer-supplied), or 'disabled' (horizontal scaling is not session-safe)."
  value       = module.this.redis_mode
  sensitive   = false
}
