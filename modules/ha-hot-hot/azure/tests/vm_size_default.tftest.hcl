# The default vm_size, and the quota reality behind it.
#
# Nothing pinned this before, so the default could be changed -- or typo'd to a
# size Azure does not sell -- and every one of the other 51 runs would still
# pass. That is how a default ships broken.
#
# Why the default is a burstable B-series rather than the Dsv5 training floor:
# every Dsv5 rung (D2s_v5 through D64s_v5) draws ONE quota pool,
# standardDSv5Family, and Azure routinely grants that pool a limit of 0 in a
# subscription that has never asked for it. A Dsv5 default therefore fails the
# apply on a fresh subscription -- and fails it LATE, because the VMs are
# created after the network, Key Vault and database, so roughly twelve minutes
# in, needing a support request to clear. B-series quota is granted by default.
#
# The trade is real and deliberate: B-series is burstable, banking CPU credits
# while idle and throttling to a fraction of a core once they are spent. It
# suits pilots and steady low load, not sustained campaign sending. The Dsv5
# ladder is still there and still the published purchasable rung; these runs
# pin that it stays reachable.

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


# The default. If this changes, it should change deliberately and visibly.
run "default_vm_size_is_b4ms" {
  command = plan

  assert {
    condition     = azurerm_linux_virtual_machine.vm[0].size == "Standard_B4ms"
    error_message = "The default vm_size must be Standard_B4ms. A Dsv5 default fails on a fresh subscription: every Dsv5 rung draws standardDSv5Family, which Azure commonly grants a limit of 0, and the VMs are created late enough that the failure lands about twelve minutes into the apply."
  }

  assert {
    condition     = azurerm_linux_virtual_machine.vm[1].size == "Standard_B4ms"
    error_message = "Both nodes of the HA pair must take the same default size."
  }
}

# 4 vCPU, not 2: it clears the 4-vCPU minimum in the ASM hardening guide, which
# a 2-vCPU default would ship underneath.
run "default_is_four_vcpu_not_two" {
  command = plan

  assert {
    condition     = azurerm_linux_virtual_machine.vm[0].size != "Standard_B2s"
    error_message = "Standard_B2s is 2 vCPU and sits below the documented 4-vCPU product minimum. It stays on the ladder as a pilot rung but must not be the default."
  }
}

# The purchasable rung has to remain reachable, or moving to production means
# leaving the module.
run "dsv5_training_floor_is_still_accepted" {
  command = plan

  variables {
    vm_size = "Standard_D8s_v5"
  }

  assert {
    condition     = azurerm_linux_virtual_machine.vm[0].size == "Standard_D8s_v5"
    error_message = "Standard_D8s_v5 must stay selectable - it is the published purchasable entry rung, and the upgrade path off the burstable default."
  }
}

# B4ms has to be ON the ladder, not merely the default: a default that the
# validation rejects fails every plan with a confusing message.
run "b4ms_passes_its_own_validation" {
  command = plan

  variables {
    vm_size = "Standard_B4ms"
  }

  assert {
    condition     = azurerm_linux_virtual_machine.vm[0].size == "Standard_B4ms"
    error_message = "Standard_B4ms must be accepted by the vm_size validation."
  }
}

# The ladder still refuses a size Azure does not sell. There is no
# Standard_D24s_v5, which is why a 24-vCore SKU cannot be delivered as a pair.
run "off_ladder_size_is_refused" {
  command = plan

  variables {
    vm_size = "Standard_D24s_v5"
  }

  expect_failures = [var.vm_size]
}
