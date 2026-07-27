# Gap C3: the other Azure HA suites all run `location = "eastus"`, never assert
# zone placement, never assert the Key Vault role assignments that gap A1 was
# about, force `create_backup_storage_account = false` so the backup path is
# untested, and never plan `db_mode = "vm"` at all.
#
# This file covers those, in North Europe — the region the Asiera deployment
# targets. North Europe supports three availability zones, which is what makes
# the two-zone VM spread and the ZoneRedundant database valid there:
# https://learn.microsoft.com/en-us/azure/reliability/regions-list

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "00000000-0000-0000-0000-000000000000"
      object_id       = "00000000-0000-0000-0000-000000000000"
      subscription_id = "00000000-0000-0000-0000-000000000000"
      client_id       = "00000000-0000-0000-0000-000000000000"
    }
  }
  mock_resource "azurerm_log_analytics_workspace" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-ne/providers/Microsoft.OperationalInsights/workspaces/mock-law" }
  }
  mock_resource "azurerm_private_dns_zone" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-ne/providers/Microsoft.Network/privateDnsZones/privatelink.redis.cache.windows.net" }
  }
  # A real subnet always has at least one address prefix; the mock provider
  # returns an empty list, which makes db_mode = "vm" fail on an index that
  # cannot fail against Azure. The module reads this CIDR to scope the db VM's
  # NSG rule and its pg_hba entry to the workload subnet.
  mock_data "azurerm_subnet" {
    defaults = {
      id                   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-ne/providers/Microsoft.Network/virtualNetworks/vnet/subnets/vm"
      address_prefixes     = ["10.0.1.0/24"]
      virtual_network_name = "vnet"
    }
  }
  mock_resource "azurerm_storage_account" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-ne/providers/Microsoft.Storage/storageAccounts/mockbackupsa" }
  }
}

mock_provider "random" {}

variables {
  product                = "sat"
  resource_group_name    = "rg-hailbytes-ne"
  location               = "northeurope"
  vm_subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-ne/providers/Microsoft.Network/virtualNetworks/vnet/subnets/vm"
  db_delegated_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-ne/providers/Microsoft.Network/virtualNetworks/vnet/subnets/db"
  private_dns_zone_id    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-ne/providers/Microsoft.Network/privateDnsZones/ne.postgres.database.azure.com"
  lb_subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-ne/providers/Microsoft.Network/virtualNetworks/vnet/subnets/lb"
  allowed_cidrs          = ["10.0.0.0/8"]
  admin_username         = "hbadmin"
  ssh_public_key         = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCVak/KSum8/0jr1oi9r9hvO8WDmnPqJWRRWXLOJiHcN5BuIwlNxHzn6gDP/ov7/UTpCqgrksYHojVdSj93bDnSU4Xi1X79aJ2AUxDwZZNQcPQDWS+x6kcE5q9Dv29xRIYGYgizF9thNJMfPEXVoLYeiA3aiR7UntjYkDgWfHJftrsPxqIo49A0Ep9tn4Qi5EVDRfy+rj04gKo3PCnM7qgYvGkXh4U4LRGji28VfzLkAe4rjo5ABHMRBOR3CQ2+nP1YHPBOOHK/v+ro7kOuPIItd99MhW5nP+/8TD+mJBJ9jFfkXXAqbk6E9lsOMHIuLIa5tuWV29oHo3IIVyw5V87F test@hailbytes"
}

# The two VMs must land in *different* zones. Both in one zone is a topology
# that costs twice as much as a single VM and survives nothing extra.
run "the_two_vms_occupy_different_zones" {
  command = plan

  assert {
    condition     = length(distinct(azurerm_linux_virtual_machine.vm[*].zone)) == 2
    error_message = "The two app VMs must be in different availability zones."
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.main[0].high_availability[0].mode == "ZoneRedundant"
    error_message = "North Europe has three zones, so the database must be ZoneRedundant here."
  }

  # A zonal Standard public IP would pin the frontend to one zone and undo the
  # VM spread. The module states zone redundancy explicitly by listing all three
  # of the region's zones rather than relying on the implicit default.
  assert {
    condition     = length(azurerm_public_ip.lb.zones) == 3
    error_message = "The load-balancer public IP must be zone-redundant across all three of North Europe's zones, not pinned to one."
  }
}

# Regression test for gap A1: the vault is rbac_authorization_enabled, so
# without a "Key Vault Secrets User" assignment per VM identity the VMs get 403
# on the DB password and the deployment never starts. This was the defect that
# made a fresh apply non-functional, and nothing asserted it.
run "every_vm_can_read_its_secrets" {
  command = plan

  assert {
    condition     = length(azurerm_role_assignment.vm_kv_secrets_user) == 2
    error_message = "Each VM's managed identity needs Key Vault Secrets User, or it gets 403 on the DB password and never boots."
  }

  assert {
    condition     = azurerm_role_assignment.vm_kv_secrets_user[0].role_definition_name == "Key Vault Secrets User"
    error_message = "Secrets User is the least-privilege role that can read a secret value; Reader cannot."
  }

  # The Redis access key has to be readable by the same identities — Azure Cache
  # for Redis has no in-VNet no-auth mode, so a cache the VMs cannot
  # authenticate to is a cache they cannot use.
  assert {
    condition     = length(azurerm_key_vault_secret.redis) == 1
    error_message = "The managed Redis access key must be stored for the VMs to fetch."
  }
}

# The backup path is forced off in the other suites, so nothing has ever planned
# it. Immutability is the property that matters: a pre-patch bundle an attacker
# (or a mistake) can delete is not a backup.
run "the_backup_container_is_immutable_and_private" {
  command = plan

  variables {
    create_backup_storage_account = true
  }

  assert {
    condition     = azurerm_storage_account.backup[0].shared_access_key_enabled == false
    error_message = "The backup account must not accept shared-key auth; the VM uploads with its managed identity."
  }

  assert {
    condition     = azurerm_storage_account.backup[0].public_network_access_enabled == false
    error_message = "The backup account must not be reachable from the internet."
  }

  assert {
    condition     = azurerm_storage_container.backup[0].container_access_type == "private"
    error_message = "The backup container must be private."
  }

  assert {
    condition     = length(azurerm_storage_container_immutability_policy.backup) == 1
    error_message = "Without an immutability policy the pre-patch bundle can be deleted before it is needed."
  }

  assert {
    condition     = length(azurerm_role_assignment.vm_backup_writer) == 2
    error_message = "Both VMs run the pre-patch backup, so both identities need write access to the container."
  }
}

# db_mode = "vm" has never been planned by any test. It provisions a third VM
# and an attached disk, and the app VMs must point at its private IP.
run "self_managed_db_mode_provisions_a_db_vm" {
  command = plan

  variables {
    db_mode = "vm"
  }

  assert {
    condition     = length(azurerm_linux_virtual_machine.db_vm) == 1
    error_message = "db_mode = \"vm\" must provision the Postgres VM."
  }

  assert {
    condition     = length(azurerm_postgresql_flexible_server.main) == 0
    error_message = "db_mode = \"vm\" must not also create a Flexible Server; that would bill for two databases."
  }

  assert {
    condition     = length(azurerm_managed_disk.db_data) == 1
    error_message = "The Postgres VM needs a data disk; the OS disk is 30 GB and is not where a database belongs."
  }

  # The db VM's identity must read the same Key Vault secret the app VMs do —
  # its cloud-init sets the hailbytes role's password from it.
  assert {
    condition     = length(azurerm_role_assignment.db_vm_kv_reader) == 1
    error_message = "The Postgres VM cannot set the hailbytes role password without reading the vault."
  }

  assert {
    condition     = output.db_mode == "vm"
    error_message = "The db_mode output must report what was actually built."
  }
}

# Slow-query logging and the delete lock (gap C4).
run "database_observability_and_delete_protection" {
  command = plan

  assert {
    condition     = azurerm_postgresql_flexible_server_configuration.log_min_duration_statement[0].value == "1000"
    error_message = "Flexible Server defaults log_min_duration_statement to -1, which logs nothing; the diagnostic setting then ships empty PostgreSQLLogs."
  }

  # Off by default: a lock makes terraform destroy fail partway through, which
  # is a worse PoC experience than an accidental delete.
  assert {
    condition     = length(azurerm_management_lock.db) == 0
    error_message = "The delete lock must be opt-in."
  }
}

run "delete_lock_protects_the_server_when_enabled" {
  command = plan

  variables {
    enable_db_delete_lock = true
  }

  assert {
    condition     = azurerm_management_lock.db[0].lock_level == "CanNotDelete"
    error_message = "ReadOnly would also block routine configuration changes; CanNotDelete is the deletion_protection analogue."
  }

  # The scope is the server's ID, which is computed and so unknown at plan —
  # not assertable here. The name is, and it encodes the intent: a lock named
  # for the resource group rather than the server would be the mistake to catch,
  # because a group-scoped CanNotDelete blocks deletion of everything in it.
  assert {
    condition     = endswith(azurerm_management_lock.db[0].name, "-pg-no-delete")
    error_message = "The lock must be named for the Postgres server it protects, and scoped to it rather than to the resource group."
  }
}

# The Key Vault name override exists because purge protection plus a 30-day
# soft-delete window makes a same-named re-create inside 30 days impossible
# (gap C5). Prove the override reaches the vault.
run "key_vault_name_can_be_overridden_for_poc_iteration" {
  command = plan

  variables {
    key_vault_name = "hbsatkv0731a"
  }

  assert {
    condition     = azurerm_key_vault.main.name == "hbsatkv0731a"
    error_message = "key_vault_name must override the derived name, or a destroyed PoC cannot be re-created for 30 days."
  }

  assert {
    condition     = azurerm_key_vault.main.purge_protection_enabled == true
    error_message = "Purge protection must stay on — disk encryption sets require it. The override is the escape hatch, not disabling protection."
  }
}

# Gap B6: CMK coverage beyond VM disks. Both managed services require a
# *user-assigned* identity — neither accepts the system-assigned one the disk
# encryption set uses — and the key URI must be versionless so the server picks
# up rotations instead of going Inaccessible when a pinned version expires.
# https://learn.microsoft.com/en-us/azure/postgresql/security/security-data-encryption
run "cmk_covers_the_database_and_the_backup_account" {
  command = plan

  variables {
    enable_customer_managed_key   = true
    create_backup_storage_account = true
  }

  assert {
    condition     = length(azurerm_user_assigned_identity.cmk) == 1
    error_message = "Flexible Server and Storage Account CMK both require a user-assigned identity; the disk encryption set's system-assigned identity cannot be reused."
  }

  assert {
    condition     = azurerm_role_assignment.cmk_kv_crypto_user[0].role_definition_name == "Key Vault Crypto Service Encryption User"
    error_message = "The CMK identity needs wrapKey/unwrapKey/get, which is exactly what Key Vault Crypto Service Encryption User grants."
  }

  # Both key IDs are computed, so a plan-time equality check against the key
  # resource is unknown on both sides. Presence is assertable; that the URI is
  # *versionless* is enforced by a static CI check, because a versioned URI pins
  # the server to one key version and takes the database Inaccessible when it
  # expires.
  assert {
    condition     = length(azurerm_postgresql_flexible_server.main[0].customer_managed_key) == 1
    error_message = "The database must be wired to the customer-managed key when CMK is enabled."
  }

  assert {
    condition     = length(azurerm_storage_account.backup[0].customer_managed_key) == 1
    error_message = "The backup account holds the pre-patch bundles and must be covered by the same key."
  }

  assert {
    condition     = one([for i in azurerm_postgresql_flexible_server.main[0].identity : i.type]) == "UserAssigned"
    error_message = "Flexible Server CMK requires a user-assigned identity; a system-assigned one is not accepted."
  }

  # The disk path must keep working alongside the new one.
  assert {
    condition     = length(azurerm_disk_encryption_set.vm) == 1
    error_message = "VM disk CMK must still be wired when CMK is enabled."
  }
}

run "cmk_defaults_off_and_provisions_no_identity" {
  command = plan

  assert {
    condition     = length(azurerm_user_assigned_identity.cmk) == 0
    error_message = "CMK is opt-in; nothing should be provisioned by default."
  }

  assert {
    condition     = length(azurerm_postgresql_flexible_server.main[0].customer_managed_key) == 0
    error_message = "The default server must use service-managed keys."
  }
}

# Azure documents that geo-redundant backup with CMK needs a second key vault
# and a *different* user-assigned identity in the paired region. This module
# provisions one vault in one region, so the combination has to fail at plan
# rather than halfway through an apply.
run "cmk_with_geo_redundant_backup_is_refused" {
  command = plan

  variables {
    enable_customer_managed_key           = true
    postgres_geo_redundant_backup_enabled = true
  }

  expect_failures = [azurerm_postgresql_flexible_server.main]
}
