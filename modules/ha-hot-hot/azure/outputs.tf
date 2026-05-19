output "load_balancer_public_ip" {
  description = "Public IP of the load balancer frontend (or App Gateway frontend when enable_application_gateway = true)."
  value       = local.appgw_endpoint
}

output "load_balancer_id" {
  value = azurerm_lb.main.id
}

output "application_gateway_id" {
  description = "ID of the Application Gateway when enable_application_gateway = true; empty otherwise."
  value       = local.enable_application_gateway ? azurerm_application_gateway.main[0].id : ""
}

output "vm_ids" {
  description = "Resource IDs of the two active/active VMs."
  value       = azurerm_linux_virtual_machine.vm[*].id
}

output "vm_private_ips" {
  value = azurerm_network_interface.vm[*].private_ip_address
}

output "postgres_fqdn" {
  description = "DB endpoint. Flexible Server FQDN in 'flexible_server' mode; private-IP:5432 of the self-managed Postgres VM in 'vm' mode."
  value       = local.db_host
}

output "db_mode" {
  description = "Active DB mode: 'flexible_server' or 'vm'."
  value       = var.db_mode
}

output "key_vault_uri" {
  description = "Key Vault URI; the DB password is at secret name 'hailbytes-db-password'."
  value       = azurerm_key_vault.main.vault_uri
}

# ----- Patching and migration safety -----

output "backup_storage_account_name" {
  description = "Name of the Storage Account configured to receive pre-patch bundles. Empty if neither create_backup_storage_account nor backup_storage_account_name is set."
  value       = local.backup_storage_account_name
}

output "backup_container_uri" {
  description = "Fully-qualified URI prefix for backup bundles."
  value       = local.backup_storage_account_name == null ? "" : "https://${local.backup_storage_account_name}.blob.core.windows.net/${local.backup_container_name}/hailbytes-${var.product}-"
}

output "pre_patch_run_command_name" {
  description = "Name of the Azure Run Command document that triggers a pre-patch backup + Flexible Server / disk snapshot."
  value       = var.enable_pre_patch_run_command ? azurerm_virtual_machine_run_command.pre_patch_backup[0].name : ""
}

output "post_patch_run_command_name" {
  description = "Name of the Azure Run Command document that runs the on-VM five-probe post-patch verifier on each VM."
  value       = var.enable_post_patch_run_command ? azurerm_virtual_machine_run_command.post_patch_verify[0].name : ""
}

output "redis_endpoint" {
  description = "Host:port of the Redis endpoint wired into the HA VMs. Either the module-provisioned Azure Cache for Redis or var.redis_endpoint_override."
  value       = local.effective_redis_host == null ? "" : "${local.effective_redis_host}:${local.effective_redis_port}"
}

output "redis_mode" {
  description = "How Redis is wired: 'managed' (this module provisioned Azure Cache), 'override' (customer-supplied endpoint), or 'disabled' (HA is not actually safe)."
  value       = local.provision_managed_redis ? "managed" : (var.redis_endpoint_override == null ? "disabled" : "override")
}

output "schema_version_endpoint" {
  description = "HTTPS URL that returns the running schema version. CI/CD post-patch verify scripts curl this."
  value       = "https://${local.appgw_endpoint}${var.schema_version_endpoint_path}"
}

output "alerts_action_group_id" {
  description = "Action Group ID for patching tripwire alerts. Empty when alert_email is null."
  value       = var.alert_email == null ? "" : azurerm_monitor_action_group.alerts[0].id
}

output "waf_attached" {
  description = "True when var.waf_policy_id was set on the App Gateway."
  value       = local.enable_application_gateway && var.waf_policy_id != null
}
