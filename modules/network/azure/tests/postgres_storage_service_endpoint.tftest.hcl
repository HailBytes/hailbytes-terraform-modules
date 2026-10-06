# The Postgres subnet must declare the Microsoft.Storage service endpoint.
#
# Azure adds it when the first Flexible Server lands in the delegated subnet
# (it carries WAL uploads to Azure Storage), so a module that leaves it out
# plans to remove it on every apply after the first. A real HA upgrade plan
# showed exactly that: "service_endpoints = [- \"Microsoft.Storage\"]" on the
# live db subnet. Microsoft documents that removing it may disrupt the
# server's connectivity.

mock_provider "azurerm" {}

variables {
  name_prefix         = "hailbytes-test"
  resource_group_name = "rg-hailbytes-test"
  location            = "northeurope"
}

run "db_subnet_keeps_the_storage_service_endpoint" {
  command = plan

  assert {
    condition     = contains(azurerm_subnet.db.service_endpoints, "Microsoft.Storage")
    error_message = "The Postgres subnet must declare the Microsoft.Storage service endpoint. Azure adds it on first server provision, and without it in config every later apply removes it from a live database subnet."
  }
}
