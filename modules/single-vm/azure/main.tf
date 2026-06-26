locals {
  name_prefix = coalesce(var.name_prefix, "hailbytes-${var.product}-${var.environment}")

  # HailBytes Marketplace publisher/offer/sku per product.
  # Publisher ID is the HailBytes Partner Center publisher; offer names match the
  # Azure Marketplace listing slugs:
  #   ASM: https://marketplace.microsoft.com/en-us/product/virtual-machines/lcmcon1687976613543.hardened_ubuntu_with_rengine
  #   SAT: https://marketplace.microsoft.com/en-us/product/virtual-machines/lcmcon1687976613543.gophish-phishing-simulator
  # To verify the exact `sku` (plan name) for your subscription, run:
  #   az vm image list --publisher lcmcon1687976613543 --offer <offer> --all -o table
  # and override via var.marketplace_sku_override if it differs.
  marketplace_plans = {
    asm = {
      publisher = "lcmcon1687976613543"
      offer     = "hardened_ubuntu_with_rengine"
      sku       = coalesce(var.marketplace_sku_override, "standard-v2")
      version   = var.marketplace_image_version
    }
    sat = {
      publisher = "lcmcon1687976613543"
      offer     = "gophish-phishing-simulator"
      sku       = coalesce(var.marketplace_sku_override, "standard-v2")
      version   = var.marketplace_image_version
    }
  }

  plan = local.marketplace_plans[var.product]

  common_tags = merge(
    {
      product     = "hailbytes-${var.product}"
      environment = var.environment
      managed-by  = "terraform"
      module      = "hailbytes-terraform-modules/single-vm/azure"
    },
    var.tags,
  )

  ingress_cidrs = var.allow_internet_ingress ? var.allowed_cidrs : [
    for c in var.allowed_cidrs : c if c != "0.0.0.0/0"
  ]

  create_backup_storage       = var.create_backup_storage_account
  backup_storage_account_name = local.create_backup_storage ? azurerm_storage_account.backup[0].name : var.backup_storage_account_name
  backup_container_name       = "hailbytes-${var.product}-bundles"
}

# ----- Marketplace agreement -----
#
# Accepts the legal terms for the HailBytes Marketplace offer. Required before
# the VM can pull from the marketplace image. Set accept_marketplace_terms = false
# if your org accepts terms through a separate central process.

resource "azurerm_marketplace_agreement" "hailbytes" {
  count = var.accept_marketplace_terms ? 1 : 0

  publisher = local.plan.publisher
  offer     = local.plan.offer
  plan      = local.plan.sku
}

# ----- Public IP (optional) -----

resource "azurerm_public_ip" "vm" {
  count = var.associate_public_ip ? 1 : 0

  name                = "${local.name_prefix}-pip"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.common_tags
}

# ----- Network: NSG -----

resource "azurerm_network_security_group" "vm" {
  name                = "${local.name_prefix}-nsg"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = local.common_tags
}

resource "azurerm_network_security_rule" "https_in" {
  for_each = { for i, c in local.ingress_cidrs : tostring(i) => c }

  name                        = "allow-https-${each.key}"
  priority                    = 100 + tonumber(each.key)
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = each.value
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.vm.name
}

resource "azurerm_network_security_rule" "deny_all_in" {
  name                        = "deny-all-inbound"
  priority                    = 4096
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.vm.name
}

resource "azurerm_network_interface" "vm" {
  name                = "${local.name_prefix}-nic"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = local.common_tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = var.associate_public_ip ? azurerm_public_ip.vm[0].id : null
  }
}

resource "azurerm_network_interface_security_group_association" "vm" {
  network_interface_id      = azurerm_network_interface.vm.id
  network_security_group_id = azurerm_network_security_group.vm.id
}

# ----- Disk encryption set (optional CMK) -----

resource "azurerm_key_vault_key" "disk" {
  count = var.enable_customer_managed_key ? 1 : 0

  name         = "${local.name_prefix}-disk-key"
  key_vault_id = var.key_vault_id
  key_type     = "RSA"
  key_size     = 4096
  key_opts     = ["decrypt", "encrypt", "sign", "unwrapKey", "verify", "wrapKey"]
}

resource "azurerm_disk_encryption_set" "vm" {
  count = var.enable_customer_managed_key ? 1 : 0

  name                = "${local.name_prefix}-des"
  resource_group_name = var.resource_group_name
  location            = var.location
  key_vault_key_id    = azurerm_key_vault_key.disk[0].id
  tags                = local.common_tags

  identity {
    type = "SystemAssigned"
  }
}

# ----- VM -----

resource "azurerm_linux_virtual_machine" "vm" {
  name                            = "${local.name_prefix}-vm"
  resource_group_name             = var.resource_group_name
  location                        = var.location
  size                            = var.vm_size
  admin_username                  = var.admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.vm.id]
  tags = merge(local.common_tags, {
    "hailbytes-${var.product}" = "true"
  })

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  identity {
    type = "SystemAssigned"
  }

  os_disk {
    caching                = "ReadWrite"
    storage_account_type   = "Premium_LRS"
    disk_size_gb           = var.os_disk_size_gb
    disk_encryption_set_id = var.enable_customer_managed_key ? azurerm_disk_encryption_set.vm[0].id : null
  }

  source_image_reference {
    publisher = local.plan.publisher
    offer     = local.plan.offer
    sku       = local.plan.sku
    version   = local.plan.version
  }

  plan {
    name      = local.plan.sku
    publisher = local.plan.publisher
    product   = local.plan.offer
  }

  boot_diagnostics {}

  depends_on = [azurerm_marketplace_agreement.hailbytes]
}

resource "azurerm_managed_disk" "data" {
  name                   = "${local.name_prefix}-data"
  resource_group_name    = var.resource_group_name
  location               = var.location
  storage_account_type   = "Premium_LRS"
  create_option          = "Empty"
  disk_size_gb           = var.data_disk_size_gb
  disk_encryption_set_id = var.enable_customer_managed_key ? azurerm_disk_encryption_set.vm[0].id : null
  tags                   = local.common_tags
}

resource "azurerm_virtual_machine_data_disk_attachment" "data" {
  managed_disk_id    = azurerm_managed_disk.data.id
  virtual_machine_id = azurerm_linux_virtual_machine.vm.id
  lun                = 0
  caching            = "ReadWrite"
}

# ----- Patching and migration safety -----
#
# Storage Account (with versioning, soft delete, immutable blob policy in
# unlocked mode so customers can extend retention later) is the Azure
# equivalent of the AWS S3 backup bucket. The VM's system-assigned managed
# identity gets least-privilege "Storage Blob Data Contributor" on this one
# container — write access for ha-pre-patch-backup.sh, nothing else.
#
# azurerm_virtual_machine_run_command bakes the pre-patch backup script in as
# a deployable Run Command document. Customers fire it from Azure Portal:
#   VM -> Operations -> Run command -> select RunPrePatchBackup
# matching the AWS "Systems Manager -> Run Command" experience.

resource "azurerm_storage_account" "backup" {
  count                           = local.create_backup_storage ? 1 : 0
  name                            = coalesce(var.backup_storage_account_name, substr(replace("${local.name_prefix}backup", "-", ""), 0, 24))
  resource_group_name             = var.resource_group_name
  public_network_access_enabled   = false
  allow_nested_items_to_be_public = false
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = var.backup_storage_replication
  account_kind                    = "StorageV2"
  access_tier                     = "Cool"
  min_tls_version                 = "TLS1_2"
  shared_access_key_enabled       = false
  tags                            = local.common_tags

  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = var.backup_blob_soft_delete_days
    }

    container_delete_retention_policy {
      days = var.backup_blob_soft_delete_days
    }
  }
}

resource "azurerm_storage_management_policy" "backup" {
  count              = local.create_backup_storage ? 1 : 0
  storage_account_id = azurerm_storage_account.backup[0].id

  rule {
    name    = "tier-and-expire"
    enabled = true
    filters {
      prefix_match = ["${local.backup_container_name}/hailbytes-${var.product}-"]
      blob_types   = ["blockBlob"]
    }
    actions {
      base_blob {
        tier_to_cool_after_days_since_modification_greater_than    = 30
        tier_to_archive_after_days_since_modification_greater_than = 90
      }
      version {
        change_tier_to_cool_after_days_since_creation    = 30
        change_tier_to_archive_after_days_since_creation = 90
        delete_after_days_since_creation                 = var.backup_blob_noncurrent_expiration_days
      }
    }
  }
}

resource "azurerm_storage_container" "backup" {
  count                 = local.create_backup_storage ? 1 : 0
  name                  = local.backup_container_name
  storage_account_id    = azurerm_storage_account.backup[0].id
  container_access_type = "private"
}

resource "azurerm_storage_container_immutability_policy" "backup" {
  count                                 = local.create_backup_storage ? 1 : 0
  storage_container_resource_manager_id = azurerm_storage_container.backup[0].id
  immutability_period_in_days           = var.backup_immutability_days
  protected_append_writes_all_enabled   = false
}

resource "azurerm_role_assignment" "vm_backup_writer" {
  count                = local.backup_storage_account_name == null ? 0 : 1
  scope                = local.create_backup_storage ? azurerm_storage_account.backup[0].id : data.azurerm_storage_account.existing_backup[0].id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_linux_virtual_machine.vm.identity[0].principal_id
}

data "azurerm_storage_account" "existing_backup" {
  count               = (!local.create_backup_storage && var.backup_storage_account_name != null) ? 1 : 0
  name                = var.backup_storage_account_name
  resource_group_name = var.resource_group_name
}

# Customer-callable Run Command document for pre-patch backup. The marketplace
# AMI provides /opt/hailbytes/bin/ha-pre-patch-backup.sh; this Run Command
# wires up AZURE_STORAGE_ACCOUNT / AZURE_STORAGE_CONTAINER, fires the script,
# and snapshots the data disk so the runbook is one click.

resource "azurerm_virtual_machine_run_command" "pre_patch_backup" {
  count              = var.enable_pre_patch_run_command ? 1 : 0
  name               = "RunPrePatchBackup"
  location           = var.location
  virtual_machine_id = azurerm_linux_virtual_machine.vm.id

  source {
    script = <<-EOSH
      #!/bin/bash
      set -euo pipefail
      TS=$(date -u +%Y-%m-%dT%H-%M-%SZ)
      export AZURE_STORAGE_ACCOUNT='${local.backup_storage_account_name == null ? "" : local.backup_storage_account_name}'
      export AZURE_STORAGE_CONTAINER='${local.backup_container_name}'
      export AZURE_BLOB_PREFIX="hailbytes-${var.product}-$${TS}"
      if [ -x /opt/hailbytes/bin/ha-pre-patch-backup.sh ]; then
        sudo -E /opt/hailbytes/bin/ha-pre-patch-backup.sh
      else
        echo "WARN: /opt/hailbytes/bin/ha-pre-patch-backup.sh not present; skipping local bundle."
      fi
      # Trigger a managed-disk snapshot via the VM's managed identity (requires
      # Disk Snapshot Contributor on this RG, see module README).
      az login --identity --allow-no-subscriptions >/dev/null
      az snapshot create \
        --resource-group '${var.resource_group_name}' \
        --name '${local.name_prefix}-pre-patch-'"$$TS" \
        --source '${azurerm_managed_disk.data.id}' \
        --incremental true \
        --tags Module=hailbytes-terraform-modules Phase=pre-patch
    EOSH
  }
}
