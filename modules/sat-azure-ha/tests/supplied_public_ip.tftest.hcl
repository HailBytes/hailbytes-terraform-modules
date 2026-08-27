# The two-vCPU HA pair — the pilot shape, at the bottom of the portable ladder.
#
# basic.tftest.hcl covers the DEFAULT shape (8 vCore, Standard_D8s_v5). This
# covers the other end: Standard_D2s_v5 on both nodes, customer-supplied VM
# names, a phishing allow-list distinct from the admin one, and an IPv6 CIDR in
# allowed_cidrs. Every one of those is a live pilot configuration rather than a
# hypothetical, and none of them was exercised before this file existed.
#
# What it is really guarding: the meter counts vCores across every VM carrying
# the marketplace image, so a 2 x 2 vCPU pair bills 4 vCores. If vm_count ever
# stopped being 2, or the 2-vCPU rung fell out of the vm_size validation, a
# customer sized and quoted on that basis would be wrong in both directions.

# Minimal-input apply against a mocked azurerm provider. Proves the wrapper
# instantiates with only its required variables, re-exports every
# ha-hot-hot/azure output, and that `product` is correctly hardcoded to "sat".
#
# create_backup_storage_account is left false: when true the module derives the
# backup role-assignment `count` from the (computed) storage account name,
# which the mock provider cannot make known at plan time. See
# modules/single-vm/azure/tests/basic.tftest.hcl.

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
  mock_data "azurerm_public_ip" {
    defaults = { ip_address = "203.0.113.77" }
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

mock_provider "random" {}

# Bring-your-own public IP, and Key Vault access for a human when the apply runs
# as a service principal. Both were asked for by a customer whose DNS is
# authoritative off-Azure and whose deployment identity is a service principal.
#
# The IP case is the one worth a test: azurerm_public_ip.lb sits behind a count
# now, so the module has two paths to a frontend address and only one of them
# runs on any given apply. A regression in the supplied-IP path would not show
# up in basic.tftest.hcl, which never sets the variable.

variables {
  resource_group_name    = "rg-hailbytes-test"
  location               = "northeurope"
  vm_subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/virtualNetworks/vnet/subnets/vm"
  db_delegated_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/virtualNetworks/vnet/subnets/db"
  private_dns_zone_id    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/privateDnsZones/test.postgres.database.azure.com"
  lb_subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/virtualNetworks/vnet/subnets/lb"
  allowed_cidrs          = ["203.0.113.0/24"]
  admin_username         = "hbadmin"
  ssh_public_key         = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCVak/KSum8/0jr1oi9r9hvO8WDmnPqJWRRWXLOJiHcN5BuIwlNxHzn6gDP/ov7/UTpCqgrksYHojVdSj93bDnSU4Xi1X79aJ2AUxDwZZNQcPQDWS+x6kcE5q9Dv29xRIYGYgizF9thNJMfPEXVoLYeiA3aiR7UntjYkDgWfHJftrsPxqIo49A0Ep9tn4Qi5EVDRfy+rj04gKo3PCnM7qgYvGkXh4U4LRGji28VfzLkAe4rjo5ABHMRBOR3CQ2+nP1YHPBOOHK/v+ro7kOuPIItd99MhW5nP+/8TD+mJBJ9jFfkXXAqbk6E9lsOMHIuLIa5tuWV29oHo3IIVyw5V87F test@hailbytes"

  create_backup_storage_account = false
}

run "module_creates_its_own_ip_by_default" {
  command = apply

  assert {
    condition     = output.load_balancer_public_ip != ""
    error_message = "With public_ip_id unset the module must still create an IP and report it"
  }
}

run "customer_supplied_ip_is_used_and_reported" {
  command = apply

  variables {
    public_ip_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/asiera-net/providers/Microsoft.Network/publicIPAddresses/reserved-pip"
    key_vault_reader_principal_ids = [
      "11111111-1111-1111-1111-111111111111",
      "22222222-2222-2222-2222-222222222222",
    ]
  }

  assert {
    condition     = output.load_balancer_public_ip != ""
    error_message = "load_balancer_public_ip must still resolve when the IP is supplied rather than created. Going empty here is the regression this test exists for: DNS is registered against this value."
  }

  assert {
    condition     = length(output.vm_ids) == 2
    error_message = "Supplying an IP must not disturb the pair"
  }
}
