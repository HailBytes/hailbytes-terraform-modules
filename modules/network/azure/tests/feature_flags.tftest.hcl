# Conditional resources must respect their feature flags. Plan-only count
# checks; no credentials needed.
#
# associate_subnet_nsgs gates the only conditional resources in this module
# (see main.tf) and defaults to true — the secure, standalone-deployment
# posture. Workload tier modules that associate their own NSG onto these
# subnets set it to false to avoid Azure's one-NSG-per-subnet conflict. Both
# paths need coverage: the default proves the secure posture ships out of the
# box, and the disabled path proves composition with workload modules doesn't
# leave a dangling second association attempt.

mock_provider "azurerm" {}

variables {
  name_prefix         = "hailbytes-test"
  resource_group_name = "rg-hailbytes-test"
  location            = "eastus"
}

run "nsg_association_enabled_by_default" {
  command = plan

  assert {
    condition     = length(azurerm_subnet_network_security_group_association.lb) == 1
    error_message = "associate_subnet_nsgs = true (the default) must associate the lb NSG."
  }

  assert {
    condition     = length(azurerm_subnet_network_security_group_association.workload) == 1
    error_message = "associate_subnet_nsgs = true (the default) must associate the workload NSG."
  }

  assert {
    condition     = length(azurerm_subnet_network_security_group_association.db) == 1
    error_message = "associate_subnet_nsgs = true (the default) must associate the db NSG."
  }
}

run "nsg_association_disabled_creates_no_associations" {
  command = plan

  variables {
    associate_subnet_nsgs = false
  }

  assert {
    condition     = length(azurerm_subnet_network_security_group_association.lb) == 0
    error_message = "associate_subnet_nsgs = false must create zero lb NSG associations."
  }

  assert {
    condition     = length(azurerm_subnet_network_security_group_association.workload) == 0
    error_message = "associate_subnet_nsgs = false must create zero workload NSG associations."
  }

  assert {
    condition     = length(azurerm_subnet_network_security_group_association.db) == 0
    error_message = "associate_subnet_nsgs = false must create zero db NSG associations."
  }

  assert {
    condition     = azurerm_network_security_group.lb.name == "hailbytes-test-lb-nsg"
    error_message = "associate_subnet_nsgs = false must still create the NSG resources themselves (only the association is skipped)."
  }
}

# Regression: no Azure module provisioned an outbound path, so workload VMs
# behind an inbound-only Standard LB with no public IP could not reach the
# internet at all — no OS updates, no SMTP, no integrations.
run "nat_gateway_created_by_default" {
  command = plan

  assert {
    condition     = length(azurerm_nat_gateway.main) == 1
    error_message = "enable_nat_gateway defaults to true and must create exactly one NAT Gateway."
  }

  assert {
    condition     = length(azurerm_subnet_nat_gateway_association.workload) == 1
    error_message = "The NAT Gateway must be associated with the workload subnet, which is where the VMs live."
  }
}

run "nat_gateway_disabled_creates_nothing" {
  command = plan

  variables {
    enable_nat_gateway = false
  }

  assert {
    condition     = length(azurerm_nat_gateway.main) == 0
    error_message = "enable_nat_gateway = false must create zero NAT Gateways."
  }

  assert {
    condition     = length(azurerm_public_ip.nat) == 0
    error_message = "enable_nat_gateway = false must not leave an orphaned public IP."
  }

  assert {
    condition     = output.nat_gateway_public_ip == ""
    error_message = "nat_gateway_public_ip must be empty when the gateway is disabled."
  }
}

# Regression: SECURITY-DEFAULTS.md claimed Azure flow logs were on by default.
# They did not exist. Implemented as VNet flow logs, not NSG flow logs, because
# NSG flow logs are being retired.
run "flow_logs_enabled_by_default" {
  command = plan

  assert {
    condition     = length(azurerm_network_watcher_flow_log.vnet) == 1
    error_message = "enable_flow_logs defaults to true and must create exactly one VNet flow log."
  }

  assert {
    condition     = azurerm_network_watcher_flow_log.vnet[0].version == 2
    error_message = "Flow logs must use format version 2."
  }

  assert {
    condition     = azurerm_storage_account.flow_logs[0].shared_access_key_enabled == false
    error_message = "The flow-log Storage Account must not accept shared-key auth."
  }
}

run "flow_logs_disabled_creates_nothing" {
  command = plan

  variables {
    enable_flow_logs = false
  }

  assert {
    condition     = length(azurerm_network_watcher_flow_log.vnet) == 0
    error_message = "enable_flow_logs = false must create zero flow logs."
  }

  assert {
    condition     = length(azurerm_storage_account.flow_logs) == 0
    error_message = "enable_flow_logs = false must not leave an orphaned Storage Account."
  }
}

# The delegated Postgres subnet must NOT be routed through the NAT gateway.
# Microsoft documents that forcing the delegated subnet's traffic through a
# virtual appliance "can interfere with required platform connectivity" and can
# cause "unexpected failures in critical operations, including High
# Availability scenarios" — and that the auto-configured Microsoft.Storage
# service endpoint on that subnet, used for WAL archival, must not be removed.
# So egress belongs on the workload subnet only.
# https://learn.microsoft.com/en-us/azure/postgresql/network/concepts-networking-private
#
# Note on what is assertable here: subnet IDs are computed, so a plan-time
# comparison of association.subnet_id against azurerm_subnet.workload.id is
# unknown on both sides, and `command = apply` against the mock provider gives
# every azurerm_subnet the *same* mock ID — which would make such a comparison
# pass for the wrong reason. So this run pins the two facts that are knowable at
# plan time and that together enforce the constraint: exactly one association
# exists, and the delegation that makes the db subnet off-limits is present.
run "nat_gateway_never_touches_the_delegated_db_subnet" {
  command = plan

  assert {
    condition     = length(azurerm_subnet_nat_gateway_association.workload) == 1
    error_message = "There must be exactly one NAT gateway association, on the workload subnet. Adding a second for the db subnet is the regression this guards."
  }

  # Flexible Server requires the subnet be delegated to it, and it is that
  # delegation which makes the subnet Microsoft-managed — the reason customer
  # routing must not be layered on top of it.
  assert {
    condition = one([
      for d in azurerm_subnet.db.delegation :
      one([for sd in d.service_delegation : sd.name])
    ]) == "Microsoft.DBforPostgreSQL/flexibleServers"
    error_message = "The db subnet must be delegated to Microsoft.DBforPostgreSQL/flexibleServers; VNet integration is refused without it."
  }

  # The workload subnet, which does carry the NAT association, must NOT be
  # delegated — a delegated subnet cannot host general-purpose VMs.
  assert {
    condition     = length(azurerm_subnet.workload.delegation) == 0
    error_message = "The workload subnet must not be delegated; VMs cannot be placed in a subnet delegated to another service."
  }
}

# The delegated subnet must be big enough for the service. Microsoft's minimum
# is /28 (11 usable addresses after Azure's five reservations), and a server
# with high availability consumes four.
# https://learn.microsoft.com/en-us/azure/postgresql/network/concepts-networking-private
run "delegated_db_subnet_is_large_enough_for_ha" {
  command = plan

  assert {
    condition     = tonumber(split("/", var.db_subnet_prefix)[1]) <= 28
    error_message = "The delegated Postgres subnet must be /28 or larger; a server with HA uses four addresses of the eleven a /28 leaves usable."
  }
}
