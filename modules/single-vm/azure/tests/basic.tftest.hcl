# Minimal-input apply against a mocked azurerm provider. No real credentials and
# no API calls. Proves the module instantiates with only its required variables
# and that the VM, NIC, NSG and console outputs are populated.
#
# NOTE on create_backup_storage_account: when true, the module derives the
# backup role-assignment `count` from the storage account's (computed) name.
# The mock provider cannot make that known at plan time and Terraform refuses to
# evaluate count/for_each from unknown values, so these tests leave it false.
# That branch is only exercisable by a real-provider plan, out of scope for the
# credential-free CI gate.

mock_provider "azurerm" {
  # The azurerm provider parses referenced resource IDs (NIC, NSG) as fully
  # qualified Azure resource IDs. The mock provider fills computed strings with
  # short random tokens, so give the referenced types valid-looking IDs.
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
  product             = "asm"
  resource_group_name = "rg-hailbytes-test"
  location            = "eastus"
  subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/virtualNetworks/vnet/subnets/snet"
  allowed_cidrs       = ["10.0.0.0/8"]
  admin_username      = "hbadmin"
  ssh_public_key      = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCVak/KSum8/0jr1oi9r9hvO8WDmnPqJWRRWXLOJiHcN5BuIwlNxHzn6gDP/ov7/UTpCqgrksYHojVdSj93bDnSU4Xi1X79aJ2AUxDwZZNQcPQDWS+x6kcE5q9Dv29xRIYGYgizF9thNJMfPEXVoLYeiA3aiR7UntjYkDgWfHJftrsPxqIo49A0Ep9tn4Qi5EVDRfy+rj04gKo3PCnM7qgYvGkXh4U4LRGji28VfzLkAe4rjo5ABHMRBOR3CQ2+nP1YHPBOOHK/v+ro7kOuPIItd99MhW5nP+/8TD+mJBJ9jFfkXXAqbk6E9lsOMHIuLIa5tuWV29oHo3IIVyw5V87F test@hailbytes"

  create_backup_storage_account = false
}

run "minimal_inputs_apply" {
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
}
