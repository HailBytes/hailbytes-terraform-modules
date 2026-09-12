# The three things a customer deployment lost time to that a plan could have
# caught, pinned so they cannot come back.
#
# 1. The Key Vault name was derived from name_prefix alone. Key Vault names are
#    GLOBALLY unique and the vault carries purge protection with a 30-day
#    soft-delete that cannot be force-purged, so a name is spent the moment a
#    stack is destroyed -- and two stacks on the same name_prefix can never
#    coexist. Changing resource_group_name to get past "resource group already
#    exists" therefore produced 400 SoftDeletedVaultDoesNotExist, whose message
#    blames recovery rather than the reuse that caused it.
#    https://learn.microsoft.com/en-us/azure/key-vault/general/soft-delete-overview
#
# 2. An Azure public IP attaches to exactly ONE resource, so the load balancer
#    and the Application Gateway cannot share the reserved address DNS already
#    points at. Azure refuses it part-way through the gateway create with
#    PublicIPAddressCannotBeUsedBySeveralResources.
#    https://learn.microsoft.com/en-us/azure/virtual-network/ip-services/public-ip-addresses
#
# 3. Azure cannot undelete a public IP. One reserved inside a deployment's own
#    resource group went with it when a failed attempt was torn down, and the
#    hostname had to be re-pointed at a newly reserved address.

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
  name_prefix            = "simsphishing"
  resource_group_name    = "rg-hailbytes-test"
  location               = "northeurope"
  vm_subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/virtualNetworks/vnet/subnets/vm"
  db_delegated_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/virtualNetworks/vnet/subnets/db"
  private_dns_zone_id    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/privateDnsZones/test.postgres.database.azure.com"
  lb_subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/virtualNetworks/vnet/subnets/lb"
  appgw_subnet_id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/virtualNetworks/vnet/subnets/appgw"
  allowed_cidrs          = ["10.0.0.0/8"]
  admin_username         = "hbadmin"
  ssh_public_key         = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCVak/KSum8/0jr1oi9r9hvO8WDmnPqJWRRWXLOJiHcN5BuIwlNxHzn6gDP/ov7/UTpCqgrksYHojVdSj93bDnSU4Xi1X79aJ2AUxDwZZNQcPQDWS+x6kcE5q9Dv29xRIYGYgizF9thNJMfPEXVoLYeiA3aiR7UntjYkDgWfHJftrsPxqIo49A0Ep9tn4Qi5EVDRfy+rj04gKo3PCnM7qgYvGkXh4U4LRGji28VfzLkAe4rjo5ABHMRBOR3CQ2+nP1YHPBOOHK/v+ro7kOuPIItd99MhW5nP+/8TD+mJBJ9jFfkXXAqbk6E9lsOMHIuLIa5tuWV29oHo3IIVyw5V87F test@hailbytes"

  create_backup_storage_account = false
}

# ----- Key Vault name -----

# The default has to stay put: flipping it would rename -- and so destroy --
# the vault of every deployment that upgrades the module ref.
run "the_suffix_is_off_by_default_so_an_upgrade_never_renames_the_vault" {
  command = plan

  assert {
    condition     = azurerm_key_vault.main.name == "simsphishingkv"
    error_message = "The derived Key Vault name changed with key_vault_name_random_suffix off. Any change here renames the vault on the next apply of every existing deployment, which destroys it along with the DB password, the session keys and the disk encryption key."
  }

  assert {
    condition     = length(random_string.kv_suffix) == 0
    error_message = "No suffix should be drawn when key_vault_name_random_suffix is off."
  }
}

run "the_suffix_is_keyed_on_the_resource_group_so_a_new_group_draws_a_new_name" {
  command = plan

  variables {
    key_vault_name_random_suffix = true
  }

  assert {
    condition     = length(random_string.kv_suffix) == 1
    error_message = "key_vault_name_random_suffix = true must draw a suffix."
  }

  # keepers are the whole point. Without them the suffix is drawn once and never
  # redrawn, so moving resource group carries the old group's vault name into
  # the new one -- which is the SoftDeletedVaultDoesNotExist failure the suffix
  # exists to prevent.
  assert {
    condition     = random_string.kv_suffix[0].keepers["resource_group"] == "rg-hailbytes-test"
    error_message = "The suffix must be keyed on resource_group_name, or changing the resource group reuses a name the destroy just spent."
  }

  assert {
    condition     = random_string.kv_suffix[0].keepers["location"] == "northeurope"
    error_message = "The suffix must be keyed on location too: a Key Vault name is global, and moving region is a rebuild."
  }

  # The name itself is unknown until apply, so assert the budget it is built to:
  # base truncated to 17 + "-" + 6 = 24, Azure's maximum. A longer suffix would
  # push a full-length name past a limit the plan cannot see.
  assert {
    condition     = random_string.kv_suffix[0].length == 6
    error_message = "The suffix must stay 6 characters: the derived name is a 17-character base plus a hyphen plus this, and Azure caps a Key Vault name at 24."
  }
}

# An explicit name is a caller pinning one they already hold. The suffix must
# not rewrite it -- that is the documented escape hatch out of a soft-delete
# deadlock, and out of this change for existing deployments.
run "an_explicit_name_wins_over_the_suffix" {
  command = plan

  variables {
    key_vault_name               = "kvsimsphishing0912"
    key_vault_name_random_suffix = true
  }

  assert {
    condition     = azurerm_key_vault.main.name == "kvsimsphishing0912"
    error_message = "key_vault_name must win over key_vault_name_random_suffix."
  }

  assert {
    condition     = length(random_string.kv_suffix) == 0
    error_message = "No suffix should be drawn when the name is supplied outright."
  }
}

# ----- One address, two frontends -----

run "the_same_address_on_both_frontends_is_refused_at_plan_time" {
  command = plan

  variables {
    enable_application_gateway = true
    appgw_tls_pfx_base64       = "TU9DSw=="
    appgw_tls_pfx_password     = "mock"
    public_ip_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-reserved-addresses/providers/Microsoft.Network/publicIPAddresses/reservation"
    appgw_public_ip_id         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-reserved-addresses/providers/Microsoft.Network/publicIPAddresses/reservation"
  }

  expect_failures = [azurerm_application_gateway.main]
}

# Two distinct reserved addresses is the configuration that costs no DNS change
# on the day, so it must plan clean.
run "two_distinct_reserved_addresses_plan_clean" {
  command = plan

  variables {
    enable_application_gateway = true
    appgw_tls_pfx_base64       = "TU9DSw=="
    appgw_tls_pfx_password     = "mock"
    public_ip_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-reserved-addresses/providers/Microsoft.Network/publicIPAddresses/lb-reservation"
    appgw_public_ip_id         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-reserved-addresses/providers/Microsoft.Network/publicIPAddresses/appgw-reservation"
  }

  assert {
    condition     = length(azurerm_public_ip.appgw) == 0
    error_message = "A supplied appgw_public_ip_id must stop the module creating an address of its own."
  }
}

# ----- Delete locks on the addresses this module creates -----

run "no_public_ip_locks_by_default" {
  command = plan

  assert {
    condition     = length(azurerm_management_lock.lb_pip) == 0
    error_message = "The public-IP delete lock must be opt-in: it blocks terraform destroy, which would leave a PoC teardown half-finished."
  }
}

run "the_lock_covers_every_address_this_module_created" {
  command = plan

  variables {
    enable_public_ip_delete_lock = true
    enable_application_gateway   = true
    appgw_tls_pfx_base64         = "TU9DSw=="
    appgw_tls_pfx_password       = "mock"
  }

  assert {
    condition     = azurerm_management_lock.lb_pip[0].lock_level == "CanNotDelete"
    error_message = "The load-balancer address must take a CanNotDelete lock; Azure has no undelete for a public IP."
  }

  assert {
    condition     = azurerm_management_lock.appgw_pip[0].lock_level == "CanNotDelete"
    error_message = "The gateway address is the one DNS points at once the gateway is the front door, so it needs the lock at least as much as the load balancer's."
  }
}

# A caller-supplied address lives in the caller's resource group, on their
# lifecycle. Locking it would be this module reaching outside its own footprint
# and leaving a lock behind on a resource it never created.
run "a_supplied_address_is_never_locked_by_this_module" {
  command = plan

  variables {
    enable_public_ip_delete_lock = true
    public_ip_id                 = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-reserved-addresses/providers/Microsoft.Network/publicIPAddresses/reservation"
  }

  assert {
    condition     = length(azurerm_management_lock.lb_pip) == 0
    error_message = "The module must not lock a public IP it did not create."
  }
}

# ----- Pre-patch Run Command -----

# azurerm_virtual_machine_run_command EXECUTES on create, so with this on, a
# first apply runs a backup against an empty instance and lets that run decide
# whether the whole deployment succeeds. It took one customer's apply red at
# resource 55 of 59.
# https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/virtual_machine_run_command
run "the_pre_patch_backup_does_not_run_during_a_first_apply" {
  command = plan

  assert {
    condition     = length(azurerm_virtual_machine_run_command.pre_patch_backup) == 0
    error_message = "enable_pre_patch_run_command must default to false: the Run Command executes on create, so a first apply runs a pointless backup against an empty instance and any non-zero exit from it fails the deployment."
  }

  assert {
    condition     = length(azurerm_virtual_machine_run_command.post_patch_verify) == 2
    error_message = "The post-patch verifier stays on by default -- executing on create is useful there, because it fails an apply whose nodes are not serving."
  }
}
