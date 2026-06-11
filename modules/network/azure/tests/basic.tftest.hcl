# Minimal-input apply against a mocked azurerm provider. No real credentials and
# no API calls. Proves the module instantiates with only its required variables
# and that every operator-facing output is populated.

mock_provider "azurerm" {
  mock_resource "azurerm_virtual_network" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/virtualNetworks/mock-vnet"
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
    error_message = "workload_subnet_id output must be non-empty"
  }

  assert {
    condition     = output.lb_subnet_id != ""
    error_message = "lb_subnet_id output must be non-empty"
  }

  assert {
    condition     = output.db_delegated_subnet_id != ""
    error_message = "db_delegated_subnet_id output must be non-empty"
  }

  assert {
    condition     = output.private_dns_zone_id != ""
    error_message = "private_dns_zone_id output must be non-empty"
  }

  assert {
    condition     = output.private_dns_zone_name == "privatelink.postgres.database.azure.com"
    error_message = "private_dns_zone_name must be the canonical Postgres Flexible Server private DNS zone name"
  }
}
