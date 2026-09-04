# Postgres HA mode, and the one value that has no azurerm representation.
#
# Zone-redundant Postgres is an OFFER ENTITLEMENT, not a regional capability. A
# subscription without it fails roughly fifteen minutes into the create:
#
#   Status: "MultiAzHaIsOfferRestricted"
#   Multi-Zone HA is not supported in this region.
#
# There is no plan-time signal for that, so the only defence is being able to
# turn HA off — and azurerm has no "Disabled" mode, so the block has to be
# omitted. It was previously unconditional, which left an entitled-subscription
# assumption baked in with no way out. These runs pin the escape hatch.

mock_provider "azurerm" {
  mock_resource "azurerm_log_analytics_workspace" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.OperationalInsights/workspaces/mock-law" }
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
  resource_group_name    = "rg-hailbytes-test"
  location               = "northeurope"
  vm_subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/virtualNetworks/vnet/subnets/vm"
  db_delegated_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/virtualNetworks/vnet/subnets/db"
  private_dns_zone_id    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/privateDnsZones/test.postgres.database.azure.com"
  lb_subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/virtualNetworks/vnet/subnets/lb"
  allowed_cidrs          = ["10.0.0.0/8"]
  admin_username         = "hbadmin"
  ssh_public_key         = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCVak/KSum8/0jr1oi9r9hvO8WDmnPqJWRRWXLOJiHcN5BuIwlNxHzn6gDP/ov7/UTpCqgrksYHojVdSj93bDnSU4Xi1X79aJ2AUxDwZZNQcPQDWS+x6kcE5q9Dv29xRIYGYgizF9thNJMfPEXVoLYeiA3aiR7UntjYkDgWfHJftrsPxqIo49A0Ep9tn4Qi5EVDRfy+rj04gKo3PCnM7qgYvGkXh4U4LRGji28VfzLkAe4rjo5ABHMRBOR3CQ2+nP1YHPBOOHK/v+ro7kOuPIItd99MhW5nP+/8TD+mJBJ9jFfkXXAqbk6E9lsOMHIuLIa5tuWV29oHo3IIVyw5V87F test@hailbytes"
}

# The default is unchanged: an entitled subscription still gets a zone-redundant
# standby without asking for it.
run "default_is_zone_redundant" {
  command = plan

  assert {
    condition     = one(azurerm_postgresql_flexible_server.main[*].high_availability)[0].mode == "ZoneRedundant"
    error_message = "The default must stay ZoneRedundant - lowering DB durability silently is worse than a failed apply."
  }
}

run "same_zone_is_honoured" {
  command = plan

  variables {
    db_high_availability_mode = "SameZone"
  }

  assert {
    condition     = one(azurerm_postgresql_flexible_server.main[*].high_availability)[0].mode == "SameZone"
    error_message = "SameZone must reach the resource - it is the middle option for a subscription without the zone-redundant offer."
  }
}

# The escape hatch. "Disabled" must produce NO high_availability block at all,
# because azurerm has no value meaning off.
run "disabled_omits_the_block_entirely" {
  command = plan

  variables {
    db_high_availability_mode = "Disabled"
  }

  assert {
    condition     = length(one(azurerm_postgresql_flexible_server.main[*].high_availability)) == 0
    error_message = "db_high_availability_mode = Disabled must omit high_availability. A block with any mode set is an HA request, which a subscription lacking the offer rejects 15 minutes into the create."
  }

  # The application tier is unaffected: it is the DATABASE that loses its
  # standby, not the hot-hot pair.
  assert {
    condition     = length(azurerm_linux_virtual_machine.vm) == 2
    error_message = "Disabling DB HA must not change the application topology - both nodes still exist."
  }
}

run "a_bogus_mode_is_refused_at_plan_time" {
  command = plan

  variables {
    db_high_availability_mode = "ZoneRedundantish"
  }

  expect_failures = [var.db_high_availability_mode]
}
