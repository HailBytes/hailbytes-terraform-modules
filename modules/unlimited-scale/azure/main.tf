locals {
  name_prefix = coalesce(var.name_prefix, "hailbytes-${var.product}-${var.environment}")

  marketplace_plans = {
    asm = {
      publisher = "hailbytes"
      offer     = "hailbytes-asm"
      sku       = "hailbytes-asm-byol"
      version   = "latest"
    }
    sat = {
      publisher = "hailbytes"
      offer     = "hailbytes-sat"
      sku       = "hailbytes-sat-byol"
      version   = "latest"
    }
  }

  plan = local.marketplace_plans[var.product]

  common_tags = merge(
    {
      product     = "hailbytes-${var.product}"
      environment = var.environment
      managed-by  = "terraform"
      module      = "hailbytes-terraform-modules/unlimited-scale/azure"
    },
    var.tags,
  )
}

data "azurerm_client_config" "current" {}

resource "azurerm_marketplace_agreement" "hailbytes" {
  count = var.accept_marketplace_terms ? 1 : 0

  publisher = local.plan.publisher
  offer     = local.plan.offer
  plan      = local.plan.sku
}

# ----- Key Vault -----

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

resource "azurerm_role_assignment" "kv_writer" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "random_password" "db" {
  length           = 32
  special          = true
  override_special = "!@#$%^&*()-_=+"
}

resource "azurerm_key_vault_secret" "db" {
  name         = "hailbytes-db-password"
  value        = random_password.db.result
  key_vault_id = azurerm_key_vault.main.id
  depends_on   = [azurerm_role_assignment.kv_writer]
}

# ----- LB -----

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
  enable_tcp_reset               = true
}

# ----- VMSS -----

resource "azurerm_linux_virtual_machine_scale_set" "main" {
  name                            = "${local.name_prefix}-vmss"
  resource_group_name             = var.resource_group_name
  location                        = var.location
  sku                             = var.vm_size
  instances                       = var.vmss_default_count
  admin_username                  = var.admin_username
  disable_password_authentication = true
  zones                           = ["1", "2", "3"]
  zone_balance                    = true
  upgrade_mode                    = "Rolling"
  tags                            = local.common_tags

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  identity {
    type = "SystemAssigned"
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

  os_disk {
    storage_account_type = "Premium_LRS"
    caching              = "ReadWrite"
  }

  network_interface {
    name    = "primary"
    primary = true

    ip_configuration {
      name      = "primary"
      primary   = true
      subnet_id = var.vm_subnet_id
      load_balancer_backend_address_pool_ids = [azurerm_lb_backend_address_pool.main.id]
    }
  }

  rolling_upgrade_policy {
    max_batch_instance_percent              = 20
    max_unhealthy_instance_percent          = 20
    max_unhealthy_upgraded_instance_percent = 20
    pause_time_between_batches              = "PT3M"
  }

  custom_data = base64encode(jsonencode({
    hailbytes = {
      mode             = "scale-out"
      key_vault_uri    = azurerm_key_vault.main.vault_uri
      db_secret_name   = azurerm_key_vault_secret.db.name
      db_fqdn          = azurerm_postgresql_flexible_server.primary.fqdn
      db_read_fqdns    = [for r in azurerm_postgresql_flexible_server.replica : r.fqdn]
      product          = var.product
    }
  }))

  boot_diagnostics {}

  depends_on = [
    azurerm_marketplace_agreement.hailbytes,
    azurerm_postgresql_flexible_server.primary,
  ]
}

# ----- Autoscale -----

resource "azurerm_monitor_autoscale_setting" "vmss" {
  name                = "${local.name_prefix}-autoscale"
  resource_group_name = var.resource_group_name
  location            = var.location
  target_resource_id  = azurerm_linux_virtual_machine_scale_set.main.id
  tags                = local.common_tags

  profile {
    name = "default"

    capacity {
      default = var.vmss_default_count
      minimum = var.vmss_min_count
      maximum = var.vmss_max_count
    }

    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_resource_id = azurerm_linux_virtual_machine_scale_set.main.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT5M"
        time_aggregation   = "Average"
        operator           = "GreaterThan"
        threshold          = var.target_cpu_percent
      }
      scale_action {
        direction = "Increase"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT3M"
      }
    }

    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_resource_id = azurerm_linux_virtual_machine_scale_set.main.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT10M"
        time_aggregation   = "Average"
        operator           = "LessThan"
        threshold          = var.target_cpu_percent - 25
      }
      scale_action {
        direction = "Decrease"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT5M"
      }
    }
  }
}

# ----- Postgres primary + replicas -----

resource "azurerm_postgresql_flexible_server" "primary" {
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
  geo_redundant_backup_enabled = true

  high_availability {
    mode = "ZoneRedundant"
  }

  tags = local.common_tags

  lifecycle {
    ignore_changes = [administrator_password, zone, high_availability[0].standby_availability_zone]
  }
}

resource "azurerm_postgresql_flexible_server_configuration" "require_ssl" {
  name      = "require_secure_transport"
  server_id = azurerm_postgresql_flexible_server.primary.id
  value     = "ON"
}

resource "azurerm_postgresql_flexible_server_database" "main" {
  name      = "hailbytes"
  server_id = azurerm_postgresql_flexible_server.primary.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

resource "azurerm_postgresql_flexible_server" "replica" {
  count = var.db_replica_count

  name                = "${local.name_prefix}-pg-replica-${count.index + 1}"
  resource_group_name = var.resource_group_name
  location            = var.location

  create_mode      = "Replica"
  source_server_id = azurerm_postgresql_flexible_server.primary.id

  delegated_subnet_id = var.db_delegated_subnet_id
  private_dns_zone_id = var.private_dns_zone_id

  tags = local.common_tags

  lifecycle {
    ignore_changes = [zone, high_availability]
  }
}

# ----- Monitor: action group + alerts -----

resource "azurerm_monitor_action_group" "alerts" {
  name                = "${local.name_prefix}-ag"
  resource_group_name = var.resource_group_name
  short_name          = substr("hb${var.product}", 0, 12)
  tags                = local.common_tags

  dynamic "email_receiver" {
    for_each = var.alert_email == null ? [] : [var.alert_email]
    content {
      name                    = "oncall"
      email_address           = email_receiver.value
      use_common_alert_schema = true
    }
  }
}

resource "azurerm_monitor_metric_alert" "db_cpu" {
  name                = "${local.name_prefix}-db-cpu-high"
  resource_group_name = var.resource_group_name
  scopes              = [azurerm_postgresql_flexible_server.primary.id]
  description         = "Postgres primary CPU high"
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"

  criteria {
    metric_namespace = "Microsoft.DBforPostgreSQL/flexibleServers"
    metric_name      = "cpu_percent"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 80
  }

  action {
    action_group_id = azurerm_monitor_action_group.alerts.id
  }

  tags = local.common_tags
}

resource "azurerm_monitor_metric_alert" "vmss_unhealthy" {
  name                = "${local.name_prefix}-vmss-unhealthy"
  resource_group_name = var.resource_group_name
  scopes              = [azurerm_linux_virtual_machine_scale_set.main.id]
  description         = "VMSS has unhealthy instances"
  severity            = 2
  frequency           = "PT1M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.Compute/virtualMachineScaleSets"
    metric_name      = "Percentage CPU"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 90
  }

  action {
    action_group_id = azurerm_monitor_action_group.alerts.id
  }

  tags = local.common_tags
}
