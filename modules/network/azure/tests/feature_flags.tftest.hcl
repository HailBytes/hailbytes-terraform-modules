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
