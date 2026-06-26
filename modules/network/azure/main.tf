locals {
  common_tags = merge(
    {
      managed-by = "terraform"
      module     = "hailbytes-terraform-modules/network/azure"
    },
    var.tags,
  )
}

resource "azurerm_virtual_network" "main" {
  name                = "${var.name_prefix}-vnet"
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = [var.vnet_address_space]
  tags                = local.common_tags
}

resource "azurerm_subnet" "lb" {
  name                 = "${var.name_prefix}-lb"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.lb_subnet_prefix]
}

resource "azurerm_subnet" "workload" {
  name                 = "${var.name_prefix}-workload"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.workload_subnet_prefix]
}

# Each subnet gets a baseline NSG. These carry no custom allow rules — Azure's
# built-in default rules already permit intra-VNet traffic and deny inbound from
# the internet, which is the correct default-deny posture for a network module
# that doesn't know the customer's allowed source ranges. The workload tier
# modules (single-vm/ha-hot-hot/unlimited-scale) layer their own allow-https
# rules on the subnets they consume.
resource "azurerm_network_security_group" "lb" {
  name                = "${var.name_prefix}-lb-nsg"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = local.common_tags
}

resource "azurerm_network_security_group" "workload" {
  name                = "${var.name_prefix}-workload-nsg"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = local.common_tags
}

resource "azurerm_network_security_group" "db" {
  name                = "${var.name_prefix}-db-nsg"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = local.common_tags
}

# Subnet/NSG associations. Gated so customers who compose this module with a
# workload tier module (which associates its own NSG to the lb/workload subnet)
# can set associate_subnet_nsgs = false to avoid a double-association conflict —
# Azure permits only one NSG per subnet. Default true keeps greenfield/standalone
# deployments secure and satisfies the subnet-must-have-an-NSG control.
resource "azurerm_subnet_network_security_group_association" "lb" {
  count                     = var.associate_subnet_nsgs ? 1 : 0
  subnet_id                 = azurerm_subnet.lb.id
  network_security_group_id = azurerm_network_security_group.lb.id
}

resource "azurerm_subnet_network_security_group_association" "workload" {
  count                     = var.associate_subnet_nsgs ? 1 : 0
  subnet_id                 = azurerm_subnet.workload.id
  network_security_group_id = azurerm_network_security_group.workload.id
}

resource "azurerm_subnet_network_security_group_association" "db" {
  count                     = var.associate_subnet_nsgs ? 1 : 0
  subnet_id                 = azurerm_subnet.db.id
  network_security_group_id = azurerm_network_security_group.db.id
}

# The Postgres Flexible Server subnet must be delegated to the Microsoft.DBforPostgreSQL/flexibleServers
# service. Required for vnet-integrated (private) Postgres.
resource "azurerm_subnet" "db" {
  name                 = "${var.name_prefix}-db"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.db_subnet_prefix]

  delegation {
    name = "postgres-flex"

    service_delegation {
      name = "Microsoft.DBforPostgreSQL/flexibleServers"

      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
      ]
    }
  }
}

# Private DNS zone for vnet-integrated Postgres Flexible Server.
resource "azurerm_private_dns_zone" "postgres" {
  name                = "privatelink.postgres.database.azure.com"
  resource_group_name = var.resource_group_name
  tags                = local.common_tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  name                  = "${var.name_prefix}-postgres-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.postgres.name
  virtual_network_id    = azurerm_virtual_network.main.id
  registration_enabled  = false
  tags                  = local.common_tags
}
