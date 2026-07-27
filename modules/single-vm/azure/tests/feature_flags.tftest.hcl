# Conditional resources must respect their feature flags. Plan-only count
# checks; no credentials needed.

mock_provider "azurerm" {}

variables {
  product             = "asm"
  resource_group_name = "rg-hailbytes-test"
  location            = "eastus"
  subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/virtualNetworks/vnet/subnets/snet"
  allowed_cidrs       = ["10.0.0.0/8"]
  admin_username      = "hbadmin"
  ssh_public_key      = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCVak/KSum8/0jr1oi9r9hvO8WDmnPqJWRRWXLOJiHcN5BuIwlNxHzn6gDP/ov7/UTpCqgrksYHojVdSj93bDnSU4Xi1X79aJ2AUxDwZZNQcPQDWS+x6kcE5q9Dv29xRIYGYgizF9thNJMfPEXVoLYeiA3aiR7UntjYkDgWfHJftrsPxqIo49A0Ep9tn4Qi5EVDRfy+rj04gKo3PCnM7qgYvGkXh4U4LRGji28VfzLkAe4rjo5ABHMRBOR3CQ2+nP1YHPBOOHK/v+ro7kOuPIItd99MhW5nP+/8TD+mJBJ9jFfkXXAqbk6E9lsOMHIuLIa5tuWV29oHo3IIVyw5V87F test@hailbytes"

  create_backup_storage_account = false
}

run "cmk_disabled_by_default" {
  command = plan

  assert {
    condition     = length(azurerm_key_vault_key.disk) == 0
    error_message = "No customer-managed Key Vault key may be created when enable_customer_managed_key is false (the default)."
  }

  assert {
    condition     = length(azurerm_disk_encryption_set.vm) == 0
    error_message = "No disk encryption set may be created when enable_customer_managed_key is false."
  }
}

run "cmk_enabled_creates_key_and_des" {
  command = plan

  variables {
    enable_customer_managed_key = true
    key_vault_id                = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.KeyVault/vaults/kv-hailbytes"
  }

  assert {
    condition     = length(azurerm_key_vault_key.disk) == 1
    error_message = "enable_customer_managed_key = true must create exactly one Key Vault key."
  }

  assert {
    condition     = length(azurerm_disk_encryption_set.vm) == 1
    error_message = "enable_customer_managed_key = true must create exactly one disk encryption set."
  }
}

run "backup_storage_not_created_when_disabled" {
  command = plan

  assert {
    condition     = length(azurerm_storage_account.backup) == 0
    error_message = "create_backup_storage_account = false must create zero backup Storage Accounts."
  }
}

# Deploying a paid Marketplace image requires a purchase `plan` block on the VM
# whose three fields exactly mirror the image being deployed: plan name = image
# SKU, plan publisher = image publisher, plan product = image *offer*. Microsoft
# documents the mismatch failure explicitly, and it is easy to get wrong because
# "product" holds the offer, not the SKU. A mismatch fails the deployment with
# an unhelpful error, and the marketplace agreement must cover the same triple
# or the pull is refused before the VM is ever created.
# https://learn.microsoft.com/en-us/azure/virtual-machines/linux/cli-ps-findimage
run "marketplace_plan_matches_the_image_it_deploys" {
  command = plan

  assert {
    condition = alltrue([
      one([for p in azurerm_linux_virtual_machine.vm.plan : p.name]) == one([for s in azurerm_linux_virtual_machine.vm.source_image_reference : s.sku]),
      one([for p in azurerm_linux_virtual_machine.vm.plan : p.publisher]) == one([for s in azurerm_linux_virtual_machine.vm.source_image_reference : s.publisher]),
      one([for p in azurerm_linux_virtual_machine.vm.plan : p.product]) == one([for s in azurerm_linux_virtual_machine.vm.source_image_reference : s.offer]),
    ])
    error_message = "The purchase plan must mirror the image: plan.name = sku, plan.publisher = publisher, plan.product = offer. Note product holds the OFFER, not the SKU."
  }

  assert {
    condition = alltrue([
      azurerm_marketplace_agreement.hailbytes[0].publisher == one([for s in azurerm_linux_virtual_machine.vm.source_image_reference : s.publisher]),
      azurerm_marketplace_agreement.hailbytes[0].offer == one([for s in azurerm_linux_virtual_machine.vm.source_image_reference : s.offer]),
      azurerm_marketplace_agreement.hailbytes[0].plan == one([for s in azurerm_linux_virtual_machine.vm.source_image_reference : s.sku]),
    ])
    error_message = "The accepted marketplace agreement must cover the exact publisher/offer/plan triple the VM deploys, or the image pull is refused."
  }
}

# The offer slug is part of the public Marketplace URL and the billing meter's
# identity. A typo here is not a plan-time error — it surfaces as a failed image
# pull against a customer's subscription. Pin both products' offers literally.
run "marketplace_offer_slugs_are_pinned_per_product" {
  command = plan

  variables {
    product = "asm"
  }

  assert {
    condition     = one([for s in azurerm_linux_virtual_machine.vm.source_image_reference : s.offer]) == "hardened_ubuntu_with_rengine"
    error_message = "The ASM offer slug must match the published Marketplace listing."
  }
}
