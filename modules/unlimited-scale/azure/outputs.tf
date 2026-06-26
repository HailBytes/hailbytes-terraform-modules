output "load_balancer_public_ip" {
  description = "Public IP fronting the deployment. App Gateway IP when enable_application_gateway = true; Standard LB IP otherwise."
  value       = local.endpoint_ip
}
output "vmss_id" {
  description = "Resource ID of the Virtual Machine Scale Set."
  value       = azurerm_linux_virtual_machine_scale_set.main.id
}

output "vmss_name" {
  description = "Name of the Virtual Machine Scale Set."
  value       = azurerm_linux_virtual_machine_scale_set.main.name
}

output "application_gateway_id" {
  description = "ID of the Application Gateway when enable_application_gateway = true; empty otherwise."
  value       = local.enable_application_gateway ? azurerm_application_gateway.main[0].id : ""
}

output "postgres_primary_fqdn" {
  description = "FQDN of the primary Azure PostgreSQL Flexible Server."
  value       = azurerm_postgresql_flexible_server.primary.fqdn
}

output "postgres_replica_fqdns" {
  description = "List of FQDNs for all PostgreSQL read replicas. Empty when postgres_replica_count is 0."
  value       = [for r in azurerm_postgresql_flexible_server.replica : r.fqdn]
}

output "key_vault_uri" {
  description = "URI of the Key Vault storing secrets and encryption keys."
  value       = azurerm_key_vault.main.vault_uri
}

output "action_group_id" {
  description = "Resource ID of the Azure Monitor action group for alert notifications."
  value       = azurerm_monitor_action_group.alerts.id
}

# ----- Patching and migration safety -----

output "backup_storage_account_name" {
  description = "Name of the Storage Account configured to receive pre-patch bundles."
  value       = local.backup_storage_account_name
}

output "backup_container_uri" {
  description = "Fully-qualified URI prefix for backup bundles."
  value       = local.backup_storage_account_name == null ? "" : "https://${local.backup_storage_account_name}.blob.core.windows.net/${local.backup_container_name}/hailbytes-${var.product}-"
}

output "pre_patch_run_command_extension_name" {
  description = "Name of the VMSS extension wrapping the pre-patch backup. Invoke via `az vmss run-command`."
  value       = var.enable_pre_patch_run_command ? azurerm_virtual_machine_scale_set_extension.pre_patch_backup[0].name : ""
}

output "post_patch_run_command_extension_name" {
  description = "Name of the VMSS extension wrapping the post-patch verifier. Invoke via `az vmss run-command`."
  value       = var.enable_post_patch_run_command ? azurerm_virtual_machine_scale_set_extension.post_patch_verify[0].name : ""
}

output "redis_endpoint" {
  description = "Host:port of the Redis endpoint wired into the VMSS launch profile. Either the module-provisioned Azure Cache or var.redis_endpoint_override."
  value       = local.effective_redis_host == null ? "" : "${local.effective_redis_host}:${local.effective_redis_port}"
}

output "redis_mode" {
  description = "How Redis is wired: 'managed' (this module provisioned Azure Cache), 'override' (customer-supplied), or 'disabled' (horizontal scaling is not session-safe)."
  value       = local.provision_managed_redis ? "managed" : (var.redis_endpoint_override == null ? "disabled" : "override")
}

output "schema_version_endpoint" {
  description = "HTTPS URL that returns the running schema version."
  value       = "https://${local.endpoint_ip}${var.schema_version_endpoint_path}"
}

output "waf_attached" {
  description = "True when var.waf_policy_id is set and an App Gateway is enabled."
  value       = local.enable_application_gateway && var.waf_policy_id != null
}
