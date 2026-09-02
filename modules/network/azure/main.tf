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

  # Required, not optional. The workload modules put this subnet in their Key
  # Vault's network ACL (virtual_network_subnet_ids), and Azure validates that
  # every subnet named in a Key Vault ACL carries the Microsoft.KeyVault service
  # endpoint -- whatever the ACL's default_action is. Without it the vault fails
  # to CREATE, and only at apply time:
  #
  #   400 VirtualNetworkNotValid / SubnetsHaveNoServiceEndpointsConfigured
  #   "Subnets <name> ... do not have ServiceEndpoints for Microsoft.KeyVault
  #    resources configured."
  #
  # terraform plan cannot see this: the check is server-side, so a plan against
  # a subnet with no endpoint succeeds and the apply then fails partway through
  # with resources already created.
  service_endpoints = ["Microsoft.KeyVault"]
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

# ----- Outbound egress: NAT Gateway -----
#
# Without this the workload VMs have no outbound path at all. They sit behind a
# Standard Load Balancer with inbound rules only and carry no public IP, and a
# Standard LB does not provide outbound SNAT to its backend pool members. The
# result is no OS security updates, no SMTP sending (which is the entire point
# of SAT), and no customer-chosen integrations.
#
# This is the counterpart of aws_nat_gateway in modules/network/aws, which
# creates one per AZ. A single NAT Gateway here is regional (non-zonal): Azure
# places it in a zone of its choosing and it is not zone-redundant, so a zonal
# outage can take egress with it while the zone-spread VMs keep serving inbound
# traffic. Per-zone NAT Gateways are the fully resilient pattern and cost one
# gateway per zone; see docs/AZURE_HA_PARITY_AUDIT.md.

resource "azurerm_public_ip" "nat" {
  count = var.enable_nat_gateway ? 1 : 0

  name                = "${var.name_prefix}-nat-pip"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.common_tags
}

resource "azurerm_nat_gateway" "main" {
  count = var.enable_nat_gateway ? 1 : 0

  name                    = "${var.name_prefix}-nat"
  resource_group_name     = var.resource_group_name
  location                = var.location
  sku_name                = "Standard"
  idle_timeout_in_minutes = var.nat_gateway_idle_timeout_minutes
  tags                    = local.common_tags
}

resource "azurerm_nat_gateway_public_ip_association" "main" {
  count = var.enable_nat_gateway ? 1 : 0

  nat_gateway_id       = azurerm_nat_gateway.main[0].id
  public_ip_address_id = azurerm_public_ip.nat[0].id
}

# Only the workload subnet needs egress. The LB subnet holds a public frontend
# and the db subnet is delegated to Flexible Server, which manages its own.
resource "azurerm_subnet_nat_gateway_association" "workload" {
  count = var.enable_nat_gateway ? 1 : 0

  subnet_id      = azurerm_subnet.workload.id
  nat_gateway_id = azurerm_nat_gateway.main[0].id
}

# ----- VNet flow logs (gap B1) -----
#
# SECURITY-DEFAULTS.md claimed "VPC Flow Logs / Azure NSG Flow Logs are enabled
# by default (enable_flow_logs = true)". The variable existed only in the AWS
# modules; nothing on the Azure side produced a flow log at all.
#
# This implements VNet flow logs rather than NSG flow logs: Microsoft has
# announced NSG flow logs' retirement in favour of VNet flow logs, so building
# the NSG variant now would be building the deprecated one. Flow logs need a
# Network Watcher in the region — Azure normally auto-creates one per region as
# NetworkWatcherRG/NetworkWatcher_<region>, which is what network_watcher_name
# and network_watcher_resource_group_name default to.

resource "azurerm_storage_account" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name                            = substr(replace("${var.name_prefix}flowlogs", "-", ""), 0, 24)
  resource_group_name             = var.resource_group_name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  min_tls_version                 = "TLS1_2"
  shared_access_key_enabled       = false
  allow_nested_items_to_be_public = false
  public_network_access_enabled   = false
  tags                            = local.common_tags

  blob_properties {
    delete_retention_policy {
      days = var.flow_log_retention_days
    }
  }
}

resource "azurerm_network_watcher_flow_log" "vnet" {
  count = var.enable_flow_logs ? 1 : 0

  name                 = "${var.name_prefix}-vnet-flowlog"
  network_watcher_name = coalesce(var.network_watcher_name, "NetworkWatcher_${var.location}")
  resource_group_name  = var.network_watcher_resource_group_name
  location             = var.location
  target_resource_id   = azurerm_virtual_network.main.id
  storage_account_id   = azurerm_storage_account.flow_logs[0].id
  enabled              = true
  version              = 2
  tags                 = local.common_tags

  retention_policy {
    enabled = true
    days    = var.flow_log_retention_days
  }
}
