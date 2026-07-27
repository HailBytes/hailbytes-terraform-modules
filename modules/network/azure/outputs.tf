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

output "nat_gateway_id" {
  description = "Resource ID of the NAT Gateway providing outbound egress for the workload subnet, or empty when enable_nat_gateway = false."
  value       = var.enable_nat_gateway ? azurerm_nat_gateway.main[0].id : ""
}

output "nat_gateway_public_ip" {
  description = "Public IP the workload subnet egresses from. Give this to customers who need to allow-list HailBytes traffic (SMTP relays, integration endpoints). Empty when enable_nat_gateway = false."
  value       = var.enable_nat_gateway ? azurerm_public_ip.nat[0].ip_address : ""
}

output "flow_log_storage_account_name" {
  description = "Storage Account receiving VNet flow logs, or empty when enable_flow_logs = false."
  value       = var.enable_flow_logs ? azurerm_storage_account.flow_logs[0].name : ""
}
