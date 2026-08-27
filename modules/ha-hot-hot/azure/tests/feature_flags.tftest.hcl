# Conditional resources must respect their feature flags, and HA must run a
# zone-redundant database. Plan-only checks; no credentials needed.

mock_provider "azurerm" {
  # Key Vault validates tenant_id as a UUID; it comes from the client_config
  # data source, which the mock provider would otherwise fill with a short token.
  # db_mode = "vm" reads the workload subnet to build the Postgres NSG rule.
  # Without a mocked address_prefixes the data source returns an empty list and
  # the rule fails on an index, which reads as a module bug rather than a
  # fixture gap. northeurope.tftest.hcl already mocks it for the same reason.
  mock_data "azurerm_subnet" {
    defaults = {
      id                   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/virtualNetworks/vnet/subnets/vm"
      address_prefixes     = ["10.0.1.0/24"]
      virtual_network_name = "vnet"
    }
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

run "redis_private_link_uses_supplied_zone" {
  command = plan

  variables {
    redis_private_dns_zone_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/privateDnsZones/privatelink.redis.cache.windows.net"
  }

  assert {
    condition     = length(azurerm_private_dns_zone.redis) == 0
    error_message = "Supplying redis_private_dns_zone_id must not create a second zone — zone names are unique per resource group and would collide."
  }

  assert {
    condition     = length(azurerm_private_endpoint.redis) == 1
    error_message = "The private endpoint is still required when the caller supplies the DNS zone."
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

  assert {
    condition     = length(azurerm_private_endpoint.redis) == 0
    error_message = "No managed Redis means no private endpoint and no access-key secret."
  }

  assert {
    condition     = length(azurerm_key_vault_secret.redis) == 0
    error_message = "No managed Redis means no access-key secret."
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

# db_mode = "external": the customer already runs Postgres, so we provision
# none. Removes the largest single Azure line item from their bill and hands
# them responsibility for availability and backups.
run "external_db_provisions_no_database" {
  command = plan

  variables {
    db_mode              = "external"
    external_db_host     = "pg.internal.example.org"
    external_db_password = "not-a-real-password"
  }

  assert {
    condition     = length(azurerm_postgresql_flexible_server.main) == 0
    error_message = "db_mode = external must create zero Flexible Servers."
  }

  assert {
    condition     = length(azurerm_linux_virtual_machine.db_vm) == 0
    error_message = "db_mode = external must create zero database VMs."
  }

  assert {
    condition     = output.postgres_fqdn == "pg.internal.example.org"
    error_message = "postgres_fqdn must report the customer-supplied host in external mode."
  }

  assert {
    condition     = output.db_is_customer_managed == true
    error_message = "db_is_customer_managed must be true in external mode — it gates the backup guarantees we advertise."
  }
}

run "external_db_still_provisions_the_app_tier" {
  command = plan

  variables {
    db_mode              = "external"
    external_db_host     = "pg.internal.example.org"
    external_db_password = "not-a-real-password"
  }

  assert {
    condition     = length(azurerm_linux_virtual_machine.vm) == 2
    error_message = "external mode changes only the database; the two app VMs remain."
  }

  assert {
    condition     = length(azurerm_redis_cache.main) == 1
    error_message = "external mode must not disturb the shared session store."
  }
}

# Regression: SECURITY-DEFAULTS.md promised Azure diagnostic settings and
# Bastion-style break-glass access. Neither existed.
run "diagnostics_on_by_default" {
  command = plan

  assert {
    condition     = length(azurerm_monitor_diagnostic_setting.lb) == 1
    error_message = "Load-balancer diagnostics must be enabled by default."
  }

  assert {
    condition     = length(azurerm_monitor_diagnostic_setting.postgres) == 1
    error_message = "Database diagnostics must be enabled by default in flexible_server mode."
  }

  assert {
    condition     = length(azurerm_log_analytics_workspace.main) == 1
    error_message = "A workspace must be created when none is supplied."
  }
}

run "diagnostics_reuse_supplied_workspace" {
  command = plan

  variables {
    log_analytics_workspace_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.OperationalInsights/workspaces/central"
  }

  assert {
    condition     = length(azurerm_log_analytics_workspace.main) == 0
    error_message = "Supplying a workspace must not create a second one — enterprises centralise these."
  }

  assert {
    condition     = length(azurerm_monitor_diagnostic_setting.lb) == 1
    error_message = "Diagnostics must still be wired when the workspace is supplied."
  }
}

run "management_access_is_opt_in" {
  command = plan

  assert {
    condition     = length(azurerm_virtual_machine_extension.aad_ssh_login) == 0
    error_message = "Break-glass SSH access must be opt-in, not on by default."
  }
}

run "management_access_installs_on_every_vm" {
  command = plan

  variables {
    enable_management_access = true
  }

  assert {
    condition     = length(azurerm_virtual_machine_extension.aad_ssh_login) == 2
    error_message = "Break-glass access is useless on only one of two VMs."
  }
}

# The admin allow-list and the phishing allow-list were one variable, which is a
# silent product failure on SAT: an operator locks the console to their office
# range, the landing pages inherit that range, and every simulation target
# outside it gets nothing. The campaign still sends. It just records no
# interactions, which reads as a product fault rather than a firewall one.
run "phish_allow_list_inherits_admin_list_by_default" {
  command = plan

  variables {
    product       = "sat"
    allowed_cidrs = ["10.0.0.0/8", "192.168.0.0/16"]
  }

  assert {
    condition     = length(azurerm_network_security_rule.lb_phish_in) == 2
    error_message = "With phish_allowed_cidrs unset, the phishing rules must mirror allowed_cidrs one-for-one — an existing deployment has to plan clean."
  }

  assert {
    condition = alltrue([
      for k, r in azurerm_network_security_rule.lb_phish_in :
      contains(["10.0.0.0/8", "192.168.0.0/16"], r.source_address_prefix)
    ])
    error_message = "The inherited phishing rules must carry the same source prefixes as the admin rules."
  }
}

run "phish_allow_list_is_independent_when_set" {
  command = plan

  variables {
    product             = "sat"
    allowed_cidrs       = ["87.44.47.0/24"]
    phish_allowed_cidrs = ["0.0.0.0/0"]
  }

  assert {
    condition = alltrue([
      for k, r in azurerm_network_security_rule.lb_phish_in :
      r.source_address_prefix == "0.0.0.0/0"
    ])
    error_message = "phish_allowed_cidrs must govern the phishing frontend on its own."
  }

  assert {
    condition = alltrue([
      for k, r in azurerm_network_security_rule.lb_https_in :
      r.source_address_prefix == "87.44.47.0/24"
    ])
    error_message = "Opening the phishing surface must NOT widen the admin surface — that is the whole point of splitting the lists."
  }
}

run "phish_allow_list_stays_inert_on_asm" {
  command = plan

  variables {
    phish_allowed_cidrs = ["0.0.0.0/0"]
  }

  assert {
    condition     = length(azurerm_network_security_rule.lb_phish_in) == 0
    error_message = "ASM has no phishing surface, so setting phish_allowed_cidrs must open nothing."
  }
}

# name_prefix governs every other resource, but a customer's host-naming
# standard constrains the VMs specifically, and `<prefix>-vm-1` satisfies
# nobody's convention. The `-vm-N` suffix and the 1-based unpadded index are
# ours, so name_prefix alone cannot reach a name like `svc-web-P-01`.
run "vm_names_default_to_the_derived_pattern" {
  command = plan

  variables {
    name_prefix = "simsphishing"
  }

  assert {
    condition = alltrue([
      for i, vm in azurerm_linux_virtual_machine.vm :
      vm.name == "simsphishing-vm-${i + 1}"
    ])
    error_message = "With vm_names unset the VMs must keep the derived <name_prefix>-vm-N names."
  }
}

run "vm_names_override_exactly" {
  command = plan

  variables {
    name_prefix = "simsphishing"
    vm_names    = ["simsphishing-web-P-01", "simsphishing-web-P-02"]
  }

  assert {
    condition     = azurerm_linux_virtual_machine.vm[0].name == "simsphishing-web-P-01"
    error_message = "vm_names[0] must name the zone-1 VM verbatim."
  }

  assert {
    condition     = azurerm_linux_virtual_machine.vm[1].name == "simsphishing-web-P-02"
    error_message = "vm_names[1] must name the zone-2 VM verbatim."
  }

  # The override is scoped to the VMs. Everything else still follows
  # name_prefix, which is what the customer asked for.
  assert {
    condition     = azurerm_public_ip.lb[0].name == "simsphishing-lb-pip"
    error_message = "vm_names must not leak into the naming of anything but the VMs."
  }
}

run "db_vm_name_overrides_the_self_managed_postgres_vm" {
  command = plan

  variables {
    name_prefix = "simsphishing"
    db_mode     = "vm"
    db_vm_name  = "simsphishing-db-P-01"
  }

  assert {
    condition     = azurerm_linux_virtual_machine.db_vm[0].name == "simsphishing-db-P-01"
    error_message = "db_vm_name must name the self-managed Postgres VM verbatim."
  }
}
