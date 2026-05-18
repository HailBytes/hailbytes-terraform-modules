output "vnet_id" {
  value = azurerm_virtual_network.main.id
}

output "vnet_name" {
  value = azurerm_virtual_network.main.name
}

output "workload_subnet_id" {
  description = "Workload subnet ID. Pass to var.subnet_id (single-vm) or var.vm_subnet_id (ha-hot-hot, unlimited-scale)."
  value       = azurerm_subnet.workload.id
}

output "lb_subnet_id" {
  description = "Load-balancer subnet ID."
  value       = azurerm_subnet.lb.id
}

output "db_delegated_subnet_id" {
  description = "Postgres Flexible Server delegated subnet ID. Pass to var.db_delegated_subnet_id."
  value       = azurerm_subnet.db.id
}

output "private_dns_zone_id" {
  description = "Private DNS zone resource ID for postgres.database.azure.com. Pass to var.private_dns_zone_id."
  value       = azurerm_private_dns_zone.postgres.id
}

output "private_dns_zone_name" {
  value = azurerm_private_dns_zone.postgres.name
}
