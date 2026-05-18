# Outputs re-exported from modules/single-vm/azure.

output "vm_id" {
  value     = module.this.vm_id
  sensitive = false
}

output "vm_name" {
  value     = module.this.vm_name
  sensitive = false
}

output "private_ip_address" {
  value     = module.this.private_ip_address
  sensitive = false
}

output "public_ip_address" {
  value     = module.this.public_ip_address
  sensitive = false
}

output "nic_id" {
  value     = module.this.nic_id
  sensitive = false
}

output "nsg_id" {
  value     = module.this.nsg_id
  sensitive = false
}

output "system_assigned_identity_principal_id" {
  value     = module.this.system_assigned_identity_principal_id
  sensitive = false
}

output "data_disk_id" {
  value     = module.this.data_disk_id
  sensitive = false
}

output "console_url" {
  value     = module.this.console_url
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

output "pre_patch_run_command_name" {
  value     = module.this.pre_patch_run_command_name
  sensitive = false
}
