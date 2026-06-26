# Outputs re-exported from modules/single-vm/azure.

output "vm_id" {
  description = "Azure resource ID of the VM."
  value       = module.this.vm_id
  sensitive   = false
}

output "vm_name" {
  description = "VM name."
  value       = module.this.vm_name
  sensitive   = false
}

output "private_ip_address" {
  description = "Private IP of the VM NIC."
  value       = module.this.private_ip_address
  sensitive   = false
}

output "public_ip_address" {
  description = "Public IP, or null if associate_public_ip is false."
  value       = module.this.public_ip_address
  sensitive   = false
}

output "nic_id" {
  description = "Network interface resource ID."
  value       = module.this.nic_id
  sensitive   = false
}

output "nsg_id" {
  description = "Network security group resource ID."
  value       = module.this.nsg_id
  sensitive   = false
}

output "system_assigned_identity_principal_id" {
  description = "Principal ID of the VM's system-assigned managed identity. Use this to grant access to Key Vault, Storage, etc."
  value       = module.this.system_assigned_identity_principal_id
  sensitive   = false
}

output "data_disk_id" {
  description = "Managed disk resource ID for the data disk."
  value       = module.this.data_disk_id
  sensitive   = false
}

output "console_url" {
  description = "Azure portal URL for the VM."
  value       = module.this.console_url
  sensitive   = false
}

# ----- Patching and migration safety -----

output "backup_storage_account_name" {
  description = "Name of the Storage Account configured to receive pre-patch bundles. Empty if neither create_backup_storage_account nor backup_storage_account_name is set."
  value       = module.this.backup_storage_account_name
  sensitive   = false
}

output "backup_container_uri" {
  description = "Fully-qualified URI prefix for backup bundles: https://<account>.blob.core.windows.net/<container>/hailbytes-{product}-..."
  value       = module.this.backup_container_uri
  sensitive   = false
}

output "pre_patch_run_command_name" {
  description = "Name of the Azure Run Command document that triggers a pre-patch backup + managed-disk snapshot. Run from Portal -> VM -> Operations -> Run command."
  value       = module.this.pre_patch_run_command_name
  sensitive   = false
}
