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
      sku       = coalesce(var.marketplace_sku_override, "hardened_ubuntu_with_rengine")
      version   = var.marketplace_image_version
    }
    sat = {
      publisher = "lcmcon1687976613543"
      offer     = "gophish-phishing-simulator"
      sku       = coalesce(var.marketplace_sku_override, "gophish-phishing-simulator")
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
  tags                            = local.common_tags

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
