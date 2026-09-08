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
# It has moved twice: Standard_B4ms -> Standard_D4s_v5 -> Standard_D2s_v3.
#
# WHY Dsv3 AND NOT Dsv5. Every Dsv5 rung draws one pool, standardDSv5Family,
# and Azure commonly grants that pool a limit of 0 to a subscription that has
# never asked for it. The VMs are created late enough that the refusal lands
# about twelve minutes into an apply, with the network, Key Vault and database
# already built. standardDSv3Family is granted a non-zero default on most
# subscriptions, so the same shape deploys first time. Preflight catches the
# Dsv5 case before anything is built, but a default that does not need
# catching is better than one that does.
#
# WHY 2 vCPU AND NOT 4. Deployability again: 2 vCPU is the smallest shape this
# stack runs on, so it is the one most likely to fit inside a regional grant
# that has never been raised. The trade is real and is stated in the wizard --
# changing vm_size REPLACES the VM, so starting small is not free.
#
# WHY NOT BURSTABLE. B-series banks CPU credits while idle and throttles to a
# fraction of a core once they are spent, which is a silent degradation under
# exactly the sustained sending a campaign does. Dsv3 gets the
# deploys-first-time property without that.
run "default_vm_size_is_two_vcpu_general_compute" {
  command = plan

  assert {
    condition     = azurerm_linux_virtual_machine.vm[0].size == "Standard_D2s_v3"
    error_message = "The default vm_size must be Standard_D2s_v3: 2 vCPU, general compute, on the Dsv3 quota pool that a fresh subscription is most likely to already have. Not Dsv5 (commonly granted 0, fails twelve minutes into an apply) and not B-series (burstable, throttles silently under campaign load)."
  }

  assert {
    condition     = azurerm_linux_virtual_machine.vm[1].size == "Standard_D2s_v3"
    error_message = "Both nodes of the HA pair must take the same default size."
  }
}

# Not burstable, whatever the rung. This is the half of the old
# default_is_four_vcpu_not_two check that still holds: that check also asserted
# 4 vCPU, on the grounds that ASM's HARDENING_GUIDE.md sets a 4-vCPU minimum
# and a 2-vCPU default would ship underneath it. That reasoning is still
# correct FOR ASM, which is why modules/asm-azure-ha keeps its own
# Standard_D4s_v5 default rather than inheriting this one. This tier module and
# the SAT wrapper start at 2 because deployability on an ungranted subscription
# was judged the bigger cost for SAT. See docs/SKU_DEPLOYMENT_MATRIX.md
# Finding 1 for the argument against, which remains on the record.
run "default_is_not_burstable" {
  command = plan

  assert {
    condition     = !startswith(azurerm_linux_virtual_machine.vm[0].size, "Standard_B")
    error_message = "The default must not be a B-series size. B-series is burstable: it banks CPU credits while idle and throttles to a fraction of a core once they are spent, which degrades campaign sending without any signal. It stays selectable; it must not be the default."
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
# What the validation still refuses, now that it checks SHAPE rather than
# membership of a hand-written list.

run "single_vcpu_size_is_refused" {
  command = plan

  variables {
    vm_size = "Standard_B1s"
  }

  # One core cannot carry the web tier, the worker and the phishing server
  # together, so this is the one size gate worth keeping.
  expect_failures = [var.vm_size]
}

run "a_malformed_size_is_refused" {
  command = plan

  variables {
    vm_size = "d4s_v5"
  }

  # Missing the Standard_ prefix. Azure would reject it at apply; rejecting it
  # at plan is free.
  expect_failures = [var.vm_size]
}

# WHAT THIS DESIGN GIVES UP, asserted so it is a recorded decision rather than
# a latent surprise.
#
# The old validation enumerated nine Dsv5 rungs and two B-series sizes, so it
# could refuse Standard_D24s_v5 -- a size that does not exist. A shape check
# cannot: "D" followed by "24" is well formed, and no regex knows Azure's SKU
# catalogue.
#
# That trade is deliberate. The enumerated list blocked two real deployments --
# Standard_B4ms while it was the only family with quota, and every family
# released after the list was written -- and refusing a size the customer can
# actually buy is a worse failure than accepting one they cannot. A
# well-formed-but-nonexistent size fails at the VM create with an explicit
# Azure error naming the size, which quickstart/explain.sh matches.
run "a_nonexistent_but_wellformed_size_is_accepted" {
  command = plan

  variables {
    vm_size = "Standard_D24s_v5"
  }

  assert {
    condition     = azurerm_linux_virtual_machine.vm[0].size == "Standard_D24s_v5"
    error_message = "A well-formed size must pass validation even when Azure has no such SKU. If this run starts failing, someone has re-added an enumerated allowlist -- which is the change that blocked Standard_B4ms and every post-2021 family. Check quota and SKU availability in preflight, not in a regex."
  }
}
