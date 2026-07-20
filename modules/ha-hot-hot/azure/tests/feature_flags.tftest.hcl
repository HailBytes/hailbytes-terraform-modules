# Conditional resources must respect their feature flags, and HA must run a
# zone-redundant database. Plan-only checks; no credentials needed.

mock_provider "azurerm" {
  # Key Vault validates tenant_id as a UUID; it comes from the client_config
  # data source, which the mock provider would otherwise fill with a short token.
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

variables {
  product                = "asm"
  resource_group_name    = "rg-hailbytes-test"
  location               = "eastus"
  vm_subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/virtualNetworks/vnet/subnets/vm"
  db_delegated_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/virtualNetworks/vnet/subnets/db"
  private_dns_zone_id    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/privateDnsZones/test.postgres.database.azure.com"
  lb_subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/virtualNetworks/vnet/subnets/lb"
  allowed_cidrs          = ["10.0.0.0/8"]
  admin_username         = "hbadmin"
  ssh_public_key         = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCVak/KSum8/0jr1oi9r9hvO8WDmnPqJWRRWXLOJiHcN5BuIwlNxHzn6gDP/ov7/UTpCqgrksYHojVdSj93bDnSU4Xi1X79aJ2AUxDwZZNQcPQDWS+x6kcE5q9Dv29xRIYGYgizF9thNJMfPEXVoLYeiA3aiR7UntjYkDgWfHJftrsPxqIo49A0Ep9tn4Qi5EVDRfy+rj04gKo3PCnM7qgYvGkXh4U4LRGji28VfzLkAe4rjo5ABHMRBOR3CQ2+nP1YHPBOOHK/v+ro7kOuPIItd99MhW5nP+/8TD+mJBJ9jFfkXXAqbk6E9lsOMHIuLIa5tuWV29oHo3IIVyw5V87F test@hailbytes"

  create_backup_storage_account = false
  backup_storage_account_name   = null
}

run "postgres_is_zone_redundant" {
  command = plan

  assert {
    condition     = azurerm_postgresql_flexible_server.main[0].high_availability[0].mode == "ZoneRedundant"
    error_message = "HA tier Postgres flexible server must be ZoneRedundant by default."
  }

  assert {
    condition     = output.db_mode == "flexible_server"
    error_message = "Default db_mode must be 'flexible_server'."
  }
}

run "managed_redis_by_default" {
  command = plan

  assert {
    condition     = length(azurerm_redis_cache.main) == 1
    error_message = "Managed Redis is the HA default and must create one Azure Cache for Redis."
  }

  assert {
    condition     = output.redis_mode == "managed"
    error_message = "redis_mode must be 'managed' by default."
  }
}

run "redis_disabled_creates_nothing" {
  command = plan

  variables {
    enable_managed_redis = false
  }

  assert {
    condition     = length(azurerm_redis_cache.main) == 0
    error_message = "enable_managed_redis = false with no override must create zero Azure Cache for Redis instances."
  }

  assert {
    condition     = output.redis_mode == "disabled"
    error_message = "redis_mode must be 'disabled' when managed Redis is off and no override is supplied."
  }
}

run "backup_storage_not_created_when_disabled" {
  command = plan

  assert {
    condition     = length(azurerm_storage_account.backup) == 0
    error_message = "create_backup_storage_account = false must create zero backup Storage Accounts."
  }
}

# Regression test for #51: app VMs had no NSG at all when vm_subnet_id
# differs from lb_subnet_id (the common case per the vm_subnet_id/lb_subnet_id
# variable docs) — SECURITY-DEFAULTS.md's "deny all inbound" claim didn't hold.
run "vm_nsg_created_and_associated_when_subnets_differ" {
  command = plan

  assert {
    condition     = length(azurerm_network_security_group.vm) == 1
    error_message = "A dedicated NSG must be created for vm_subnet_id when it differs from lb_subnet_id."
  }

  assert {
    condition     = length(azurerm_subnet_network_security_group_association.vm) == 1
    error_message = "The VM NSG must be associated with vm_subnet_id by default (associate_vm_subnet_nsg = true)."
  }
}

run "vm_nsg_association_skipped_when_disabled" {
  command = plan

  variables {
    associate_vm_subnet_nsg = false
  }

  assert {
    condition     = length(azurerm_network_security_group.vm) == 1
    error_message = "The VM NSG must still be created (and exported via vm_nsg_id) even when the association is opted out."
  }

  assert {
    condition     = length(azurerm_subnet_network_security_group_association.vm) == 0
    error_message = "associate_vm_subnet_nsg = false must skip the subnet association."
  }
}

run "no_duplicate_vm_nsg_when_subnets_match" {
  command = plan

  variables {
    lb_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/virtualNetworks/vnet/subnets/vm"
  }

  assert {
    condition     = length(azurerm_network_security_group.vm) == 0
    error_message = "No second NSG should be created when vm_subnet_id == lb_subnet_id — a subnet can only have one associated NSG, and the lb NSG already covers it."
  }

  assert {
    condition     = output.vm_nsg_id == ""
    error_message = "vm_nsg_id must be empty when vm_subnet_id == lb_subnet_id."
  }
}
