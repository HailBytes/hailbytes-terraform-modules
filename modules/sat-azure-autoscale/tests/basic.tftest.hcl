# Minimal-input apply against a mocked azurerm provider. Proves the wrapper
# instantiates with only its required variables, re-exports every
# unlimited-scale/azure output, and that `product` is correctly hardcoded to
# "sat".
#
# create_backup_storage_account is left false: when true the module derives the
# backup role-assignment `count` from the (computed) storage account name,
# which the mock provider cannot make known at plan time. See
# modules/single-vm/azure/tests/basic.tftest.hcl.

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "00000000-0000-0000-0000-000000000000"
      object_id       = "00000000-0000-0000-0000-000000000000"
      subscription_id = "00000000-0000-0000-0000-000000000000"
      client_id       = "00000000-0000-0000-0000-000000000000"
    }
  }
  mock_resource "azurerm_key_vault" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.KeyVault/vaults/mock-kv" }
  }
  mock_resource "azurerm_public_ip" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/publicIPAddresses/mock-pip" }
  }
  mock_resource "azurerm_network_security_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/networkSecurityGroups/mock-nsg" }
  }
  mock_resource "azurerm_postgresql_flexible_server" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.DBforPostgreSQL/flexibleServers/mock-pg" }
  }
  mock_resource "azurerm_redis_cache" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Cache/redis/mock-redis" }
  }
  mock_resource "azurerm_lb_backend_address_pool" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/loadBalancers/mock-lb/backendAddressPools/mock-pool" }
  }
  mock_resource "azurerm_lb" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/loadBalancers/mock-lb" }
  }
  mock_resource "azurerm_monitor_action_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/microsoft.insights/actionGroups/mock-ag" }
  }
  mock_resource "azurerm_lb_probe" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/loadBalancers/mock-lb/probes/mock-probe" }
  }
  mock_resource "azurerm_linux_virtual_machine_scale_set" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Compute/virtualMachineScaleSets/mock-vmss" }
  }
}

mock_provider "random" {}

variables {
  resource_group_name    = "rg-hailbytes-test"
  location               = "eastus"
  vm_subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/virtualNetworks/vnet/subnets/vm"
  db_delegated_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/virtualNetworks/vnet/subnets/db"
  private_dns_zone_id    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/privateDnsZones/test.postgres.database.azure.com"
  allowed_cidrs          = ["10.0.0.0/8"]
  admin_username         = "hbadmin"
  ssh_public_key         = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCVak/KSum8/0jr1oi9r9hvO8WDmnPqJWRRWXLOJiHcN5BuIwlNxHzn6gDP/ov7/UTpCqgrksYHojVdSj93bDnSU4Xi1X79aJ2AUxDwZZNQcPQDWS+x6kcE5q9Dv29xRIYGYgizF9thNJMfPEXVoLYeiA3aiR7UntjYkDgWfHJftrsPxqIo49A0Ep9tn4Qi5EVDRfy+rj04gKo3PCnM7qgYvGkXh4U4LRGji28VfzLkAe4rjo5ABHMRBOR3CQ2+nP1YHPBOOHK/v+ro7kOuPIItd99MhW5nP+/8TD+mJBJ9jFfkXXAqbk6E9lsOMHIuLIa5tuWV29oHo3IIVyw5V87F test@hailbytes"

  create_backup_storage_account = false
}

run "wrapper_outputs_populated" {
  command = apply

  assert {
    condition     = output.load_balancer_public_ip != ""
    error_message = "load_balancer_public_ip output must be non-empty"
  }

  assert {
    condition     = output.vmss_id != ""
    error_message = "vmss_id output must be non-empty"
  }

  assert {
    condition     = output.vmss_name != ""
    error_message = "vmss_name output must be non-empty"
  }

  assert {
    condition     = output.postgres_primary_fqdn != ""
    error_message = "postgres_primary_fqdn output must be non-empty"
  }

  assert {
    condition     = output.key_vault_uri != ""
    error_message = "key_vault_uri output must be non-empty"
  }

  assert {
    condition     = output.redis_endpoint != ""
    error_message = "redis_endpoint output must be non-empty when managed Redis is enabled (the default)"
  }

  assert {
    condition     = output.redis_mode != ""
    error_message = "redis_mode output must be re-exported"
  }

  assert {
    condition     = output.post_patch_run_command_extension_name != ""
    error_message = "post_patch_run_command_extension_name output must be re-exported"
  }
}
