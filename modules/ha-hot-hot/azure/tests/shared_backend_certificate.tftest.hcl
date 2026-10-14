# Shared backend TLS certificate (opt-in).
#
# The image makes its own self-signed certificate at first boot, so App Gateway
# could trust only the VM it was read from: on 2026-10-13 a replaced VM was
# untrusted and the gateway served 502. With shared_backend_certificate every VM
# fetches one Key Vault certificate the gateway trusts.
#
# Mocks are copied from admin_public_url.tftest.hcl: the payload is only known
# after an apply, and the provider parses the ids it is handed.

mock_provider "azurerm" {
  mock_resource "azurerm_log_analytics_workspace" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.OperationalInsights/workspaces/mock-law" }
  }
  # The azurerm provider parses referenced values as fully qualified Azure
  # resource IDs; the mock provider fills computed strings with short tokens.
  mock_resource "azurerm_network_interface" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/networkInterfaces/mock-nic" }
  }
  mock_resource "azurerm_lb_backend_address_pool" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/loadBalancers/mock-lb/backendAddressPools/mock-pool" }
  }
  mock_resource "azurerm_lb" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/loadBalancers/mock-lb" }
  }
  mock_resource "azurerm_application_gateway" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/applicationGateways/mock-appgw" }
  }
  mock_resource "azurerm_linux_virtual_machine" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Compute/virtualMachines/mock-vm" }
  }
  mock_resource "azurerm_user_assigned_identity" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/mock-vm-id" }
  }
  mock_resource "azurerm_managed_disk" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Compute/disks/mock-disk" }
  }
  mock_resource "azurerm_network_security_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/networkSecurityGroups/mock-nsg" }
  }
  mock_resource "azurerm_public_ip" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/publicIPAddresses/mock-pip" }
  }
  mock_resource "azurerm_postgresql_flexible_server" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.DBforPostgreSQL/flexibleServers/mock-pg" }
  }
  mock_resource "azurerm_key_vault" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.KeyVault/vaults/mock-kv" }
  }
  mock_resource "azurerm_private_dns_zone" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/privateDnsZones/privatelink.redis.cache.windows.net" }
  }
  mock_resource "azurerm_redis_cache" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Cache/redis/mock-redis" }
  }
  # Key Vault validates tenant_id as a UUID; it comes from the client_config
  # data source, which the mock provider would otherwise fill with a short token.
  mock_resource "azurerm_key_vault_certificate" {
    defaults = {
      id                      = "https://mock-kv.vault.azure.net/certificates/hailbytes-backend-tls/00000000000000000000000000000000"
      certificate_data_base64 = "TU9DSw=="
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
  product                = "sat"
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

# On: one certificate, and every VM is told where it is, so a replacement
# fetches the same certificate instead of minting its own.
run "on_gives_every_vm_the_same_certificate" {
  command = apply

  variables {
    shared_backend_certificate = true
  }

  assert {
    condition     = length(azurerm_key_vault_certificate.backend) == 1 && length(azurerm_role_assignment.kv_certificates_officer) == 1
    error_message = "One certificate, and the deployer needs Key Vault Certificates Officer to create it."
  }

  assert {
    condition = alltrue([for vm in azurerm_linux_virtual_machine.vm :
    nonsensitive(jsondecode(base64decode(vm.custom_data)).hailbytes.backend_cert_secret_name) == "hailbytes-backend-tls"])
    error_message = "Every app VM's payload must name the shared certificate, or a VM keeps a certificate the gateway does not trust."
  }

  # App Gateway v2 matches the backend host against the CN; this is the CN
  # the image's own certificate has always had.
  assert {
    condition     = one(one(azurerm_key_vault_certificate.backend[0].certificate_policy).x509_certificate_properties).subject == "CN=hailbytes-sat-admin"
    error_message = "The shared certificate's CN must match the gateway's backend host, or the gateway serves 502."
  }

  assert {
    condition = (
      one(one(azurerm_key_vault_certificate.backend[0].certificate_policy).key_properties).exportable &&
      one(one(azurerm_key_vault_certificate.backend[0].certificate_policy).secret_properties).content_type == "application/x-pem-file"
    )
    error_message = "The VMs install the private key from the certificate's PEM secret, so it must be exportable and PEM."
  }

  # An unattended renewal re-keys in Key Vault while the gateway still trusts
  # the old certificate and the VMs keep serving it until they restart.
  assert {
    condition = alltrue([for a in one(azurerm_key_vault_certificate.backend[0].certificate_policy).lifetime_action :
    one(a.action).action_type != "AutoRenew"])
    error_message = "The shared certificate must not auto-renew: it would split the VMs and the gateway onto different certificates."
  }
}

# Off by default: an older image cannot read the certificate. (That the default
# SAT payload gains no field is pinned in sat_payload_unchanged, which has its
# own state; custom_data is in ignore_changes, so a VM here keeps the payload
# the first run gave it -- the same reason switching on needs both trusted.)
run "off_by_default" {
  command = plan

  assert {
    condition     = length(azurerm_key_vault_certificate.backend) == 0 && length(azurerm_role_assignment.kv_certificates_officer) == 0
    error_message = "The shared backend certificate must be opt-in: an older image cannot read it."
  }
}
