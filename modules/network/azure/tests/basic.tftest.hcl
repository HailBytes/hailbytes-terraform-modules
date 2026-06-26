# Minimal-input apply against a mocked azurerm provider. No real credentials and
# no API calls. Proves the module instantiates with only its required variables
# and that every operator-facing output is populated.
#
# The Azure network module creates a vnet, three subnets (lb, workload, and a
# Postgres-delegated db subnet), a baseline NSG per subnet, a private DNS zone
# for Postgres Flexible Server, and a DNS zone virtual-network link. All
# resources are unconditional, so a single apply run covers the full surface.
#
# azurerm_network_security_group is mocked with a well-formed ID because the
# azurerm_subnet_network_security_group_association resource validates the NSG
# ID format; the mock provider's random token would otherwise fail that check.

mock_provider "azurerm" {
  mock_resource "azurerm_virtual_network" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/virtualNetworks/mock-vnet"
    }
  }

  mock_resource "azurerm_subnet" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/virtualNetworks/mock-vnet/subnets/mock-snet"
    }
  }

  mock_resource "azurerm_network_security_group" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/networkSecurityGroups/mock-nsg"
    }
  }

  mock_resource "azurerm_private_dns_zone" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/privateDnsZones/privatelink.postgres.database.azure.com"
    }
  }
}

variables {
  name_prefix         = "hailbytes-test"
  resource_group_name = "rg-hailbytes-test"
  location            = "eastus"
}

run "minimal_inputs_apply" {
  command = apply

  assert {
    condition     = output.vnet_id != ""
    error_message = "vnet_id output must be non-empty"
  }

  assert {
    condition     = output.vnet_name != ""
    error_message = "vnet_name output must be non-empty"
  }

  assert {
    condition     = output.workload_subnet_id != ""
    error_message = "workload_subnet_id output must be non-empty (pass to var.subnet_id / var.vm_subnet_id on workload modules)"
  }

  assert {
    condition     = output.lb_subnet_id != ""
    error_message = "lb_subnet_id output must be non-empty"
  }

  assert {
    condition     = output.db_delegated_subnet_id != ""
    error_message = "db_delegated_subnet_id output must be non-empty (pass to var.db_delegated_subnet_id on ha-hot-hot / unlimited-scale)"
  }

  assert {
    condition     = output.private_dns_zone_id != ""
    error_message = "private_dns_zone_id output must be non-empty (pass to var.private_dns_zone_id on ha-hot-hot / unlimited-scale)"
  }

  assert {
    condition     = output.private_dns_zone_name == "privatelink.postgres.database.azure.com"
    error_message = "private_dns_zone_name must be the well-known Postgres Flexible Server FQDN"
  }
}
