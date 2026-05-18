output "load_balancer_public_ip" {
  description = "Public IP of the load balancer frontend."
  value       = azurerm_public_ip.lb.ip_address
}

output "load_balancer_id" {
  value = azurerm_lb.main.id
}

output "vm_ids" {
  description = "Resource IDs of the two active/active VMs."
  value       = azurerm_linux_virtual_machine.vm[*].id
}

output "vm_private_ips" {
  value = azurerm_network_interface.vm[*].private_ip_address
}

output "postgres_fqdn" {
  description = "FQDN of the Postgres Flexible Server (private, vnet-integrated)."
  value       = azurerm_postgresql_flexible_server.main.fqdn
}

output "key_vault_uri" {
  description = "Key Vault URI; the DB password is at secret name 'hailbytes-db-password'."
  value       = azurerm_key_vault.main.vault_uri
}
