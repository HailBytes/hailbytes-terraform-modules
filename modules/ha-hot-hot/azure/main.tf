locals {
  name_prefix = coalesce(var.name_prefix, "hailbytes-${var.product}-${var.environment}")

  # Listing slugs from the published Azure Marketplace offers:
  #   ASM: lcmcon1687976613543.hardened_ubuntu_with_rengine
  #   SAT: lcmcon1687976613543.gophish-phishing-simulator
  # Verify the SKU (plan name) for your subscription with:
  #   az vm image list --publisher lcmcon1687976613543 --offer <offer> --all -o table
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
      module      = "hailbytes-terraform-modules/ha-hot-hot/azure"
    },
    var.tags,
  )

  vm_count = 2
  vm_zones = ["1", "2"]
}

resource "azurerm_marketplace_agreement" "hailbytes" {
  count = var.accept_marketplace_terms ? 1 : 0

  publisher = local.plan.publisher
  offer     = local.plan.offer
  plan      = local.plan.sku
}

# ----- Key Vault for DB creds -----

data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "main" {
  name                       = substr(replace("${local.name_prefix}-kv", "-", ""), 0, 24)
  resource_group_name        = var.resource_group_name
  location                   = var.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  purge_protection_enabled   = true
  soft_delete_retention_days = 30
  enable_rbac_authorization  = true
  tags                       = local.common_tags
}

resource "random_password" "db" {
  length           = 32
  special          = true
  override_special = "!@#$%^&*()-_=+"
}

resource "azurerm_role_assignment" "kv_secret_writer" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_key_vault_secret" "db" {
  name         = "hailbytes-db-password"
  value        = random_password.db.result
  key_vault_id = azurerm_key_vault.main.id

  depends_on = [azurerm_role_assignment.kv_secret_writer]
}

# ----- NSG -----

resource "azurerm_network_security_group" "lb" {
  name                = "${local.name_prefix}-lb-nsg"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = local.common_tags
}

resource "azurerm_network_security_rule" "lb_https_in" {
  for_each = { for i, c in var.allowed_cidrs : tostring(i) => c }

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
  network_security_group_name = azurerm_network_security_group.lb.name
}

# ----- Load Balancer -----

resource "azurerm_public_ip" "lb" {
  name                = "${local.name_prefix}-lb-pip"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  tags                = local.common_tags
}

resource "azurerm_lb" "main" {
  name                = "${local.name_prefix}-lb"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Standard"
  tags                = local.common_tags

  frontend_ip_configuration {
    name                 = "frontend"
    public_ip_address_id = azurerm_public_ip.lb.id
  }
}

resource "azurerm_lb_backend_address_pool" "main" {
  loadbalancer_id = azurerm_lb.main.id
  name            = "backend"
}

resource "azurerm_lb_probe" "https" {
  loadbalancer_id     = azurerm_lb.main.id
  name                = "health"
  protocol            = "Https"
  port                = 443
  request_path        = "/health"
  interval_in_seconds = 15
  number_of_probes    = 2
}

resource "azurerm_lb_rule" "https" {
  loadbalancer_id                = azurerm_lb.main.id
  name                           = "https"
  protocol                       = "Tcp"
  frontend_port                  = 443
  backend_port                   = 443
  frontend_ip_configuration_name = "frontend"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.main.id]
  probe_id                       = azurerm_lb_probe.https.id
  idle_timeout_in_minutes        = 4
  enable_tcp_reset               = true
}

# ----- VMs -----

resource "azurerm_network_interface" "vm" {
  count = local.vm_count

  name                = "${local.name_prefix}-nic-${count.index + 1}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = local.common_tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = var.vm_subnet_id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_interface_backend_address_pool_association" "vm" {
  count = local.vm_count

  network_interface_id    = azurerm_network_interface.vm[count.index].id
  ip_configuration_name   = "primary"
  backend_address_pool_id = azurerm_lb_backend_address_pool.main.id
}

resource "azurerm_linux_virtual_machine" "vm" {
  count = local.vm_count

  name                            = "${local.name_prefix}-vm-${count.index + 1}"
  resource_group_name             = var.resource_group_name
  location                        = var.location
  size                            = var.vm_size
  zone                            = local.vm_zones[count.index]
  admin_username                  = var.admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.vm[count.index].id]
  tags                            = local.common_tags

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  identity {
    type = "SystemAssigned"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 64
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

  # The marketplace image reads instance metadata (tags) to wire itself to the shared DB.
  custom_data = base64encode(jsonencode({
    hailbytes = {
      mode               = "ha"
      key_vault_uri      = azurerm_key_vault.main.vault_uri
      db_secret_name     = azurerm_key_vault_secret.db.name
      db_fqdn            = azurerm_postgresql_flexible_server.main.fqdn
      product            = var.product
      cluster_member_idx = count.index
    }
  }))

  depends_on = [
    azurerm_marketplace_agreement.hailbytes,
    azurerm_postgresql_flexible_server.main,
  ]
}

resource "azurerm_managed_disk" "data" {
  count = local.vm_count

  name                 = "${local.name_prefix}-data-${count.index + 1}"
  resource_group_name  = var.resource_group_name
  location             = var.location
  storage_account_type = "Premium_LRS"
  create_option        = "Empty"
  disk_size_gb         = var.data_disk_size_gb
  zone                 = local.vm_zones[count.index]
  tags                 = local.common_tags
}

resource "azurerm_virtual_machine_data_disk_attachment" "data" {
  count = local.vm_count

  managed_disk_id    = azurerm_managed_disk.data[count.index].id
  virtual_machine_id = azurerm_linux_virtual_machine.vm[count.index].id
  lun                = 0
  caching            = "ReadWrite"
}

# ----- Postgres Flexible Server -----

resource "azurerm_postgresql_flexible_server" "main" {
  name                = "${local.name_prefix}-pg"
  resource_group_name = var.resource_group_name
  location            = var.location
  version             = var.db_version

  sku_name   = var.db_sku_name
  storage_mb = var.db_storage_mb

  administrator_login    = "hailbytes"
  administrator_password = random_password.db.result

  delegated_subnet_id = var.db_delegated_subnet_id
  private_dns_zone_id = var.private_dns_zone_id

  backup_retention_days        = var.db_backup_retention_days
  geo_redundant_backup_enabled = false

  high_availability {
    mode = var.db_high_availability_mode
  }

  tags = local.common_tags

  lifecycle {
    ignore_changes = [administrator_password, zone, high_availability[0].standby_availability_zone]
  }
}

resource "azurerm_postgresql_flexible_server_configuration" "require_ssl" {
  name      = "require_secure_transport"
  server_id = azurerm_postgresql_flexible_server.main.id
  value     = "ON"
}

resource "azurerm_postgresql_flexible_server_database" "main" {
  name      = "hailbytes"
  server_id = azurerm_postgresql_flexible_server.main.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}
