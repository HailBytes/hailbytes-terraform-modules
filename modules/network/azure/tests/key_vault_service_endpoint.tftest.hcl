# The workload subnet must carry the Microsoft.KeyVault service endpoint.
#
# The workload modules name this subnet in their Key Vault's network ACL, and
# Azure rejects a Key Vault whose ACL references a subnet without that endpoint
# -- with 400 SubnetsHaveNoServiceEndpointsConfigured, at APPLY time, because
# the validation is server-side. A real deployment lost an apply to this.
#
# This assertion is cheap and mock-testable precisely because it checks the
# declared attribute rather than Azure's response.

mock_provider "azurerm" {}

variables {
  name_prefix         = "hailbytes-test"
  resource_group_name = "rg-hailbytes-test"
  location            = "northeurope"
}

run "workload_subnet_has_the_key_vault_service_endpoint" {
  command = plan

  assert {
    condition     = contains(azurerm_subnet.workload.service_endpoints, "Microsoft.KeyVault")
    error_message = "The workload subnet must carry the Microsoft.KeyVault service endpoint, or the workload modules' Key Vault fails to create with 400 SubnetsHaveNoServiceEndpointsConfigured - at apply, after other resources exist."
  }
}
