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
