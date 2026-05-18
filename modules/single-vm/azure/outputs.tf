output "vm_id" {
  description = "Azure resource ID of the VM."
  value       = azurerm_linux_virtual_machine.vm.id
}

output "vm_name" {
  description = "VM name."
  value       = azurerm_linux_virtual_machine.vm.name
}

output "private_ip_address" {
  description = "Private IP of the VM NIC."
  value       = azurerm_network_interface.vm.private_ip_address
}

output "public_ip_address" {
  description = "Public IP, or null if associate_public_ip is false."
  value       = var.associate_public_ip ? azurerm_public_ip.vm[0].ip_address : null
}

output "nic_id" {
  description = "Network interface resource ID."
  value       = azurerm_network_interface.vm.id
}

output "nsg_id" {
  description = "Network security group resource ID."
  value       = azurerm_network_security_group.vm.id
}

output "system_assigned_identity_principal_id" {
  description = "Principal ID of the VM's system-assigned managed identity. Use this to grant access to Key Vault, Storage, etc."
  value       = azurerm_linux_virtual_machine.vm.identity[0].principal_id
}

output "data_disk_id" {
  description = "Managed disk resource ID for the data disk."
  value       = azurerm_managed_disk.data.id
}

output "console_url" {
  description = "Azure portal URL for the VM."
  value       = "https://portal.azure.com/#@/resource${azurerm_linux_virtual_machine.vm.id}"
}

# ----- Patching and migration safety -----

output "backup_storage_account_name" {
  description = "Name of the Storage Account configured to receive pre-patch bundles. Empty if neither create_backup_storage_account nor backup_storage_account_name is set."
  value       = local.backup_storage_account_name
}

output "backup_container_uri" {
  description = "Fully-qualified URI prefix for backup bundles: https://<account>.blob.core.windows.net/<container>/hailbytes-{product}-..."
  value       = local.backup_storage_account_name == null ? "" : "https://${local.backup_storage_account_name}.blob.core.windows.net/${local.backup_container_name}/hailbytes-${var.product}-"
}

output "pre_patch_run_command_name" {
  description = "Name of the Azure Run Command document that triggers a pre-patch backup + managed-disk snapshot. Run from Portal -> VM -> Operations -> Run command."
  value       = var.enable_pre_patch_run_command ? azurerm_virtual_machine_run_command.pre_patch_backup[0].name : ""
}
