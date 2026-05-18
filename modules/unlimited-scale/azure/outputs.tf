output "load_balancer_public_ip" { value = azurerm_public_ip.lb.ip_address }
output "vmss_id" { value = azurerm_linux_virtual_machine_scale_set.main.id }
output "vmss_name" { value = azurerm_linux_virtual_machine_scale_set.main.name }
output "postgres_primary_fqdn" { value = azurerm_postgresql_flexible_server.primary.fqdn }
output "postgres_replica_fqdns" { value = [for r in azurerm_postgresql_flexible_server.replica : r.fqdn] }
output "key_vault_uri" { value = azurerm_key_vault.main.vault_uri }
output "action_group_id" { value = azurerm_monitor_action_group.alerts.id }
