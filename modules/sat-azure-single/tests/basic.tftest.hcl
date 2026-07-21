# Minimal-input apply against a mocked azurerm provider. Proves the wrapper
# instantiates with only its required variables, re-exports every
# single-vm/azure output, and that `product` is correctly hardcoded to "sat".
#
# create_backup_storage_account is left false: when true the module derives the
# backup role-assignment `count` from the storage account's (computed) name,
# which the mock provider cannot make known at plan time. See
# modules/single-vm/azure/tests/basic.tftest.hcl.

mock_provider "azurerm" {
  mock_resource "azurerm_network_interface" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/networkInterfaces/mock-nic" }
  }
  mock_resource "azurerm_network_security_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/networkSecurityGroups/mock-nsg" }
  }
  mock_resource "azurerm_managed_disk" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Compute/disks/mock-disk" }
  }
  mock_resource "azurerm_linux_virtual_machine" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Compute/virtualMachines/mock-vm" }
  }
}

variables {
  resource_group_name = "rg-hailbytes-test"
  location            = "eastus"
  subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/virtualNetworks/vnet/subnets/snet"
  allowed_cidrs       = ["10.0.0.0/8"]
  admin_username      = "hbadmin"
  ssh_public_key      = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCVak/KSum8/0jr1oi9r9hvO8WDmnPqJWRRWXLOJiHcN5BuIwlNxHzn6gDP/ov7/UTpCqgrksYHojVdSj93bDnSU4Xi1X79aJ2AUxDwZZNQcPQDWS+x6kcE5q9Dv29xRIYGYgizF9thNJMfPEXVoLYeiA3aiR7UntjYkDgWfHJftrsPxqIo49A0Ep9tn4Qi5EVDRfy+rj04gKo3PCnM7qgYvGkXh4U4LRGji28VfzLkAe4rjo5ABHMRBOR3CQ2+nP1YHPBOOHK/v+ro7kOuPIItd99MhW5nP+/8TD+mJBJ9jFfkXXAqbk6E9lsOMHIuLIa5tuWV29oHo3IIVyw5V87F test@hailbytes"

  create_backup_storage_account = false
}

run "wrapper_outputs_populated" {
  command = apply

  assert {
    condition     = output.vm_id != ""
    error_message = "vm_id output must be non-empty"
  }

  assert {
    condition     = output.vm_name != ""
    error_message = "vm_name output must be non-empty"
  }

  assert {
    condition     = output.nic_id != ""
    error_message = "nic_id output must be non-empty"
  }

  assert {
    condition     = output.nsg_id != ""
    error_message = "nsg_id output must be non-empty"
  }

  assert {
    condition     = output.console_url != ""
    error_message = "console_url output must be non-empty"
  }

  assert {
    condition     = output.pre_patch_run_command_name != ""
    error_message = "pre_patch_run_command_name output must be non-empty"
  }
}
