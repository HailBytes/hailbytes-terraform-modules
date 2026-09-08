# db_mode = "external" through the SAT HA WRAPPER.
#
# This mode was unreachable here: variables.tf restricted db_mode to
# ["flexible_server", "vm"] while main.tf already forwarded every external_db_*
# variable to ha-hot-hot and outputs.tf already documented
# db_is_customer_managed. The wrapper forbade the one mode its own passthrough
# and outputs supported, so "external" failed validation at this layer and
# nowhere else.
#
# Scope, deliberately narrow: resource-level proof that no database is built
# already lives in ha-hot-hot/azure/tests/feature_flags.tftest.hcl
# ("external_db_provisions_no_database"). Duplicating it here is impossible
# anyway -- those resources sit in a child module and a test can only address
# the root. What is unique to THIS layer is that the wrapper accepts the mode
# and forwards it faithfully, so that is what these assertions cover.
#
# Also pinned here: external mode must not require db_delegated_subnet_id or
# private_dns_zone_id. Both are omitted from the fixture below on purpose. They
# were required variables regardless of mode, which forced an operator choosing
# external into a Postgres-delegated subnet and a private DNS zone that nothing
# would ever reference, plus the permissions to create them. If either becomes
# required again this test stops planning.
#
# NOT claimed: that the app reaches that host. Reachability from vm_subnet_id,
# TLS on the far end, and DDL rights for external_db_username are real-apply
# concerns no mock provider can settle.

mock_provider "azurerm" {
  mock_resource "azurerm_network_interface" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/networkInterfaces/mock-nic" }
  }
  mock_resource "azurerm_lb_backend_address_pool" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/loadBalancers/mock-lb/backendAddressPools/mock-pool" }
  }
  mock_resource "azurerm_lb" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/loadBalancers/mock-lb" }
  }
  mock_resource "azurerm_application_gateway" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/applicationGateways/mock-appgw" }
  }
  mock_resource "azurerm_linux_virtual_machine" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Compute/virtualMachines/mock-vm" }
  }
  mock_resource "azurerm_managed_disk" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Compute/disks/mock-disk" }
  }
  mock_resource "azurerm_network_security_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/networkSecurityGroups/mock-nsg" }
  }
  mock_resource "azurerm_public_ip" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/publicIPAddresses/mock-pip" }
  }
  mock_resource "azurerm_postgresql_flexible_server" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.DBforPostgreSQL/flexibleServers/mock-pg" }
  }
  mock_resource "azurerm_key_vault" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.KeyVault/vaults/mock-kv" }
  }
  mock_resource "azurerm_redis_cache" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Cache/redis/mock-redis" }
  }
  mock_resource "azurerm_log_analytics_workspace" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.OperationalInsights/workspaces/mock-law" }
  }
  mock_resource "azurerm_private_dns_zone" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/privateDnsZones/privatelink.redis.cache.windows.net" }
  }
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "00000000-0000-0000-0000-000000000000"
      object_id       = "00000000-0000-0000-0000-000000000000"
      subscription_id = "00000000-0000-0000-0000-000000000000"
      client_id       = "00000000-0000-0000-0000-000000000000"
    }
  }
}

variables {
  resource_group_name = "rg-hailbytes-test"
  location            = "eastus"
  vm_subnet_id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/virtualNetworks/vnet/subnets/vm"
  lb_subnet_id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/virtualNetworks/vnet/subnets/lb"
  allowed_cidrs       = ["10.0.0.0/8"]
  admin_username      = "hbadmin"
  ssh_public_key      = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCVak/KSum8/0jr1oi9r9hvO8WDmnPqJWRRWXLOJiHcN5BuIwlNxHzn6gDP/ov7/UTpCqgrksYHojVdSj93bDnSU4Xi1X79aJ2AUxDwZZNQcPQDWS+x6kcE5q9Dv29xRIYGYgizF9thNJMfPEXVoLYeiA3aiR7UntjYkDgWfHJftrsPxqIo49A0Ep9tn4Qi5EVDRfy+rj04gKo3PCnM7qgYvGkXh4U4LRGji28VfzLkAe4rjo5ABHMRBOR3CQ2+nP1YHPBOOHK/v+ro7kOuPIItd99MhW5nP+/8TD+mJBJ9jFfkXXAqbk6E9lsOMHIuLIa5tuWV29oHo3IIVyw5V87F test@hailbytes"

  create_backup_storage_account = false

  # External mode provisions no server, so the delegated subnet and private DNS
  # zone a Flexible Server needs are deliberately omitted here. Leaving them out
  # is itself part of the point: this mode drops those prerequisites.
  db_mode              = "external"
  external_db_host     = "pg.corp.example.net"
  external_db_port     = 5432
  external_db_name     = "hailbytes"
  external_db_username = "hailbytes"
  external_db_password = "not-a-real-password-mock-only"
  external_db_sslmode  = "verify-full"
}

run "external_mode_reports_the_supplied_host" {
  command = plan

  assert {
    condition     = output.postgres_fqdn == "pg.corp.example.net"
    error_message = "postgres_fqdn must echo external_db_host verbatim in external mode, so an operator can confirm what the app will dial."
  }

  assert {
    condition     = output.db_mode == "external"
    error_message = "db_mode output must report external."
  }

  assert {
    condition     = output.db_is_customer_managed
    error_message = "db_is_customer_managed must be true in external mode; it is what tells an operator backups and PITR are theirs."
  }
}
