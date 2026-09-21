# Upgrade-safety invariants for modules/ha-hot-hot/azure.
#
# Customers pin this module to a commit SHA and bump it deliberately. What makes
# that bump safe is not that the module is tested -- it is that the bump does
# not rename, replace or remove anything underneath a running deployment. These
# are the values that decide that, and every one of them forces a replacement if
# it moves.
#
# HOW TO USE IT ON A PR THAT CHANGES THIS MODULE. Copy this file unchanged into
# a worktree of the base ref and run it there too:
#
#   git worktree add --detach /tmp/base <base-sha>
#   cp modules/ha-hot-hot/azure/tests/upgrade_parity.tftest.hcl \
#      /tmp/base/modules/ha-hot-hot/azure/tests/
#   (cd /tmp/base/modules/ha-hot-hot/azure && terraform init -backend=false && \
#    terraform test -filter=tests/upgrade_parity.tftest.hcl)
#
# Both runs must pass. A file that passes only at HEAD is not evidence of
# anything: it means the new behaviour is self-consistent, not that it is the
# same behaviour a customer already has.
#
# Verified this way for PR #108 against 25e46dd -- 6 passed at both refs.
#
# Inputs are the shape a real customer deployment uses: an explicit name_prefix,
# a caller-supplied load-balancer address, no App Gateway yet, database standby
# off. Nothing here opts into anything new -- that is the point. A new feature
# that only shows up when you ask for it cannot disturb an upgrade; one that
# changes a default can.

mock_provider "azurerm" {
  mock_resource "azurerm_log_analytics_workspace" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-parity/providers/Microsoft.OperationalInsights/workspaces/mock-law" }
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

variables {
  product                = "sat"
  environment            = "prod"
  name_prefix            = "simsphishing"
  resource_group_name    = "simsphishing-rg-X-01"
  location               = "northeurope"
  vm_subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-parity/providers/Microsoft.Network/virtualNetworks/vnet/subnets/vm"
  db_delegated_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-parity/providers/Microsoft.Network/virtualNetworks/vnet/subnets/db"
  private_dns_zone_id    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-parity/providers/Microsoft.Network/privateDnsZones/ne.postgres.database.azure.com"
  lb_subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-parity/providers/Microsoft.Network/virtualNetworks/vnet/subnets/lb"
  allowed_cidrs          = ["87.44.47.0/24"]
  admin_username         = "hbadmin"
  ssh_public_key         = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCVak/KSum8/0jr1oi9r9hvO8WDmnPqJWRRWXLOJiHcN5BuIwlNxHzn6gDP/ov7/UTpCqgrksYHojVdSj93bDnSU4Xi1X79aJ2AUxDwZZNQcPQDWS+x6kcE5q9Dv29xRIYGYgizF9thNJMfPEXVoLYeiA3aiR7UntjYkDgWfHJftrsPxqIo49A0Ep9tn4Qi5EVDRfy+rj04gKo3PCnM7qgYvGkXh4U4LRGji28VfzLkAe4rjo5ABHMRBOR3CQ2+nP1YHPBOOHK/v+ro7kOuPIItd99MhW5nP+/8TD+mJBJ9jFfkXXAqbk6E9lsOMHIuLIa5tuWV29oHo3IIVyw5V87F test@hailbytes"

  vm_names                      = ["simsphishing-web-P-01", "simsphishing-web-P-02"]
  vm_size                       = "Standard_D2s_v3"
  db_high_availability_mode     = "Disabled"
  enable_pre_patch_run_command  = false
  create_backup_storage_account = false
  accept_marketplace_terms      = false
  enable_managed_redis          = false
  public_ip_id                  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-reserved/providers/Microsoft.Network/publicIPAddresses/reservation"
}

# THE one that matters most. The Key Vault holds the database password, the
# session keys and the disk encryption key, its name is its identity to Azure,
# and a rename is a destroy -- cascading into the disk encryption set and every
# disk it encrypts, then reserving the old name for 30 days so the ref cannot be
# rolled back. If this value ever differs between two refs, upgrading to the
# later one destroys the deployment.
run "the_key_vault_name_is_unchanged" {
  command = plan

  # Both refs warn that a Disabled standby is not database HA. Expected, and
  # asserted so that losing the warning is also a failure.
  expect_failures = [check.database_has_a_standby]

  assert {
    condition     = azurerm_key_vault.main.name == "simsphishingkv"
    error_message = "The derived Key Vault name moved. Upgrading to this ref RENAMES and therefore DESTROYS the vault of every deployment that did not pin key_vault_name."
  }
}

# Renaming a VM replaces it, which on a two-node pair is a full outage.
run "the_vm_names_and_zones_are_unchanged" {
  command = plan

  # Both refs warn that a Disabled standby is not database HA. Expected, and
  # asserted so that losing the warning is also a failure.
  expect_failures = [check.database_has_a_standby]

  assert {
    condition     = azurerm_linux_virtual_machine.vm[0].name == "simsphishing-web-P-01"
    error_message = "VM 0 name moved; renaming an Azure VM replaces it."
  }
  assert {
    condition     = azurerm_linux_virtual_machine.vm[1].name == "simsphishing-web-P-02"
    error_message = "VM 1 name moved; renaming an Azure VM replaces it."
  }
  assert {
    condition     = azurerm_linux_virtual_machine.vm[0].zone == "1" && azurerm_linux_virtual_machine.vm[1].zone == "2"
    error_message = "VM zone placement moved; changing a VM's zone replaces it."
  }
}

# The database is the one thing in the stack with no rebuild path that keeps the
# data. Its name, its zone pin and its sku all force replacement.
run "the_database_identity_is_unchanged" {
  command = plan

  # Both refs warn that a Disabled standby is not database HA. Expected, and
  # asserted so that losing the warning is also a failure.
  expect_failures = [check.database_has_a_standby]

  assert {
    condition     = azurerm_postgresql_flexible_server.main[0].name == "simsphishing-pg"
    error_message = "Postgres server name moved; that is a replacement, and a restore."
  }
  assert {
    condition     = azurerm_postgresql_flexible_server.main[0].zone == "1"
    error_message = "The single-zone database's zone pin moved; changing a Flexible Server's zone replaces it."
  }
  assert {
    condition     = azurerm_postgresql_flexible_server.main[0].sku_name == "GP_Standard_D2ds_v5"
    error_message = "The database sku default moved, which resizes a live server on the next apply."
  }
}

# A caller-supplied address must stay attached to the load balancer and must
# stay unmanaged -- the module creating one alongside means the frontend moved.
run "the_supplied_address_is_still_the_frontend" {
  command = plan

  # Both refs warn that a Disabled standby is not database HA. Expected, and
  # asserted so that losing the warning is also a failure.
  expect_failures = [check.database_has_a_standby]

  assert {
    condition     = length(azurerm_public_ip.lb) == 0
    error_message = "The module created a load-balancer address despite public_ip_id being supplied, so the frontend -- and DNS -- moved."
  }
  assert {
    condition     = azurerm_lb.main.name == "simsphishing-lb"
    error_message = "Load balancer name moved, which replaces it and with it the frontend."
  }
}

# Names of the remaining stateful or identity-bearing resources. Each of these
# forces replacement of something that takes a real outage to rebuild.
run "the_other_resource_names_are_unchanged" {
  command = plan

  # Both refs warn that a Disabled standby is not database HA. Expected, and
  # asserted so that losing the warning is also a failure.
  expect_failures = [check.database_has_a_standby]

  assert {
    condition     = azurerm_managed_disk.data[0].name == "simsphishing-data-1"
    error_message = "Data disk 0 name moved, which replaces the disk and loses what is on it."
  }
  assert {
    condition     = azurerm_managed_disk.data[1].name == "simsphishing-data-2"
    error_message = "Data disk 1 name moved, which replaces the disk and loses what is on it."
  }
  # CMK is off by default, so there is no disk encryption set to name. Assert
  # the absence: one appearing by default would replace every disk it covers.
  assert {
    condition     = length(azurerm_disk_encryption_set.vm) == 0
    error_message = "A disk encryption set appeared without enable_customer_managed_key."
  }
  assert {
    condition     = azurerm_network_security_group.lb.name == "simsphishing-lb-nsg"
    error_message = "LB NSG name moved."
  }
}

# Nothing new may be created by default. A resource that appears without being
# asked for is a surprise in a customer's plan at best, and a bill at worst.
run "no_new_resources_appear_by_default" {
  command = plan

  # Both refs warn that a Disabled standby is not database HA. Expected, and
  # asserted so that losing the warning is also a failure.
  expect_failures = [check.database_has_a_standby]

  assert {
    condition     = length(azurerm_management_lock.db) == 0
    error_message = "A database lock appeared without enable_db_delete_lock."
  }
  assert {
    condition     = length(azurerm_redis_cache.main) == 0
    error_message = "A Redis cache appeared without enable_managed_redis."
  }
  assert {
    condition     = length(azurerm_application_gateway.main) == 0
    error_message = "An Application Gateway appeared without enable_application_gateway."
  }
  assert {
    condition     = length(azurerm_storage_account.backup) == 0
    error_message = "A backup storage account appeared without create_backup_storage_account."
  }
}
