output "vnet_id" {
  description = "Resource ID of the virtual network. Pass to workload modules that need to peer or reference the VNet."
  value       = azurerm_virtual_network.main.id
}

output "vnet_name" {
  description = "Name of the virtual network. Required when creating VNet peerings or referencing subnets via the Azure portal."
  value       = azurerm_virtual_network.main.name
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
  description = "Name of the private DNS zone for Postgres (e.g. '<prefix>.postgres.database.azure.com'). Pass to var.private_dns_zone_name on ha-hot-hot / unlimited-scale."
  value       = azurerm_private_dns_zone.postgres.name
}
