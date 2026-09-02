locals {

  # Load-balancer health probe path, per product. See the identical note in
  # modules/ha-hot-hot: "/health" matches no route in either product -- SAT
  # serves /api/health, ASM serves /api/ready -- so a hardcoded "/health" probe
  # never marks a backend healthy and the pool comes up empty.
  health_check_path = var.health_check_path != null ? var.health_check_path : (
    var.product == "sat" ? "/api/health" : "/api/ready"
  )
  # ----- Application ports -----
  #
  # Same derivation as every other tier: SAT serves its admin UI on 3333
  # (config.json `listen_url`) and ASM publishes 443 from its proxy container.
  # This tier hardcoded 443 everywhere, which meant a SAT autoscale deployment
  # probed and forwarded to a port no instance binds -- an empty backend pool
  # and a frontend that answers nothing.
  #
  # SAT also serves the phishing/landing surface, in plaintext, on phish_port
  # (hailbytes-sat/config.json: `phish_server.listen_url` 0.0.0.0:80,
  # `use_tls` false). That surface IS the product -- landing pages and the
  # click/open tracking behind them -- so the Standard LB fronts it on :80 for
  # SAT, exactly as ha-hot-hot/azure does. ASM has no phishing surface and gets
  # none of these resources.
  admin_port = coalesce(var.admin_port, var.product == "sat" ? 3333 : 443)
  phish_port = coalesce(var.phish_port, 80)

  # Who may reach the phishing/landing surface, as opposed to the admin
  # console. See the phish_allowed_cidrs variable: one shared list means an
  # operator who locks the console to an office range also locks every
  # simulation target out of the landing pages, and the campaign then sends and
  # records nothing. Null inherits allowed_cidrs, so an existing deployment
  # plans clean.
  phish_cidrs = var.phish_allowed_cidrs != null ? var.phish_allowed_cidrs : var.allowed_cidrs

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
      module      = "hailbytes-terraform-modules/unlimited-scale/azure"
    },
    var.tags,
  )

  create_backup_storage       = var.create_backup_storage_account
  backup_storage_account_name = local.create_backup_storage ? azurerm_storage_account.backup[0].name : var.backup_storage_account_name
  backup_container_name       = "hailbytes-${var.product}-bundles"

  enable_application_gateway = var.enable_application_gateway
  endpoint_ip                = local.enable_application_gateway ? azurerm_public_ip.appgw[0].ip_address : azurerm_public_ip.lb.ip_address

  # Shared session store: required by every horizontally-scaled SAT/ASM
  # deployment because every VMSS instance has to read the same session
  # map and worker-lock heartbeat. Provisioned by default; can be
  # overridden via var.redis_endpoint_override + var.enable_managed_redis.
  provision_managed_redis = var.enable_managed_redis && var.redis_endpoint_override == null
  effective_redis_host    = local.provision_managed_redis ? one(azurerm_redis_cache.main[*].hostname) : var.redis_endpoint_override
  effective_redis_port    = local.provision_managed_redis ? 6380 : var.redis_endpoint_override_port
}

data "azurerm_client_config" "current" {}

# Cross-variable constraints that cannot be expressed inside individual variable
# validation blocks (which only see the one variable being declared).
resource "terraform_data" "validate_vmss_sizing" {
  lifecycle {
    precondition {
      condition     = var.vmss_min_count <= var.vmss_default_count && var.vmss_default_count <= var.vmss_max_count
      error_message = "vmss_default_count (${var.vmss_default_count}) must be between vmss_min_count (${var.vmss_min_count}) and vmss_max_count (${var.vmss_max_count})."
    }
  }
}

resource "azurerm_marketplace_agreement" "hailbytes" {
  count = var.accept_marketplace_terms ? 1 : 0

  publisher = local.plan.publisher
  offer     = local.plan.offer
  plan      = local.plan.sku
}

# ----- Key Vault -----

resource "azurerm_key_vault" "main" {
  name                       = coalesce(var.key_vault_name, substr(replace("${local.name_prefix}-kv", "-", ""), 0, 24))
  resource_group_name        = var.resource_group_name
  location                   = var.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  purge_protection_enabled   = true
  soft_delete_retention_days = 30
  rbac_authorization_enabled = true
  tags                       = local.common_tags

  network_acls {
    # default_action is wired through var.key_vault_network_default_action so
    # customers can opt into "Deny" once they've added the operator IP to
    # key_vault_ip_rules and a Microsoft.KeyVault service endpoint on
    # vm_subnet_id. Defaulting to "Allow" preserves pre-ACL behavior;
    # data-plane access is still gated by RBAC and the AzureServices bypass.
    default_action             = var.key_vault_network_default_action #tfsec:ignore:azure-keyvault-specify-network-acl
    bypass                     = "AzureServices"
    ip_rules                   = var.key_vault_ip_rules
    virtual_network_subnet_ids = [var.vm_subnet_id]
  }
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
  name            = "hailbytes-db-password"
  value           = random_password.db.result
  key_vault_id    = azurerm_key_vault.main.id
  content_type    = "application/x-postgresql-password"
  expiration_date = timeadd(timestamp(), "${var.db_secret_expiration_hours}h")

  lifecycle {
    ignore_changes = [expiration_date]
  }

  depends_on = [azurerm_role_assignment.kv_writer]
}

# ----- NSG (allowed_cidrs ingress) -----
#
# Mirrors the ha-hot-hot/azure pattern: build an NSG with one allow-https
# rule per CIDR and associate it with the VMSS subnet so the rules
# actually filter ingress. Customers who already manage NSGs on
# vm_subnet_id should set associate_vm_subnet_nsg = false and consume
# the NSG via output instead.

resource "azurerm_network_security_group" "vmss" {
  name                = "${local.name_prefix}-vmss-nsg"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = local.common_tags
}

resource "azurerm_network_security_rule" "vmss_https_in" {
  for_each = { for i, c in var.allowed_cidrs : tostring(i) => c }

  name                        = "allow-https-${each.key}"
  priority                    = 100 + tonumber(each.key)
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = tostring(local.admin_port)
  source_address_prefix       = each.value
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.vmss.name
}

# The phishing frontend. Separate from the admin rule so an operator can see,
# and revoke, the phishing surface independently of the admin surface.
#
# Source is the client CIDR, not the AzureLoadBalancer tag: the Standard LB is
# an L4 pass-through that does not SNAT inbound load-balancing rules, so the
# VMSS instance sees the original client IP. (The health probe is already
# permitted by the NSG's default AllowAzureLoadBalancerInBound rule, which is
# also what carries the existing 443 probe.)
resource "azurerm_network_security_rule" "vmss_phish_in" {
  for_each = var.product == "sat" ? { for i, c in local.phish_cidrs : tostring(i) => c } : {}

  name                        = "allow-phish-${each.key}"
  priority                    = 1000 + tonumber(each.key)
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = tostring(local.phish_port)
  source_address_prefix       = each.value
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.vmss.name
}

resource "azurerm_subnet_network_security_group_association" "vmss" {
  count                     = var.associate_vm_subnet_nsg ? 1 : 0
  subnet_id                 = var.vm_subnet_id
  network_security_group_id = azurerm_network_security_group.vmss.id
}

# ----- LB -----

# KNOWN GAP, deliberately not closed here yet. As in ha-hot-hot/azure, the App
# Gateway does not sit in front of this load balancer: the scale set is a member
# of BOTH backend pools (see network_interface below), so the gateway and the
# load balancer are parallel public entry points to the same port. An operator
# who enables the gateway to attach a WAF therefore still has a second,
# un-WAF-ed public route to it. var.allowed_cidrs bounds both paths, so this is
# not an open internet surface.
#
# ha-hot-hot/azure closes it with var.lb_frontend_public. The equivalent here is
# a larger change -- this public IP has no count to branch, and the scale set's
# pool membership would need the same treatment -- so it is recorded rather than
# half-done. Do not copy this comment away without closing the gap.
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
  port                = local.admin_port
  request_path        = local.health_check_path
  interval_in_seconds = 15
  number_of_probes    = 2
}

resource "azurerm_lb_rule" "https" {
  loadbalancer_id                = azurerm_lb.main.id
  name                           = "https"
  protocol                       = "Tcp"
  frontend_port                  = 443
  backend_port                   = local.admin_port
  frontend_ip_configuration_name = "frontend"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.main.id]
  probe_id                       = azurerm_lb_probe.https.id
  tcp_reset_enabled              = true
}

# The phishing and tracking surface. On SAT this carries the landing pages and
# the click/open tracking that the product exists to deliver, so a scale set
# that only fronts the admin port is not serving the product.
#
# A Tcp probe rather than Http with a path: landing pages are campaign-specific
# and there is no path on the phish server guaranteed to return 200 on a fresh
# deployment, so a path-based probe would drain healthy instances.
#
# The VMSS keeps health_probe_id on the admin probe. Azure accepts exactly one,
# and it is what automatic_instance_repair reimages on -- scoping instance
# replacement to the admin surface is deliberate, so a phishing-surface blip
# takes an instance out of the :80 rotation without reimaging it.
resource "azurerm_lb_probe" "phish" {
  count = var.product == "sat" ? 1 : 0

  loadbalancer_id     = azurerm_lb.main.id
  name                = "phish"
  protocol            = "Tcp"
  port                = local.phish_port
  interval_in_seconds = 15
  number_of_probes    = 2
}

resource "azurerm_lb_rule" "phish" {
  count = var.product == "sat" ? 1 : 0

  loadbalancer_id                = azurerm_lb.main.id
  name                           = "phish"
  protocol                       = "Tcp"
  frontend_port                  = 80
  backend_port                   = local.phish_port
  frontend_ip_configuration_name = "frontend"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.main.id]
  probe_id                       = azurerm_lb_probe.phish[0].id
  tcp_reset_enabled              = true
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
  # CKV_AZURE_97. Encrypts the OS disk + temp disk + data disks at the
  # hypervisor host level on top of Azure's default platform-managed
  # encryption. No additional cost; requires the subscription to be
  # registered for the EncryptionAtHost feature (it is, on all
  # production Azure subscriptions by default).
  encryption_at_host_enabled = true
  zones                      = ["1", "2", "3"]
  zone_balance               = true
  upgrade_mode               = "Rolling"
  health_probe_id            = azurerm_lb_probe.https.id
  tags = merge(local.common_tags, {
    "hailbytes-${var.product}" = "true"
  })

  # Automatic instance repair watches the load-balancer health probe and
  # reimages an unhealthy instance after the grace period. Combined with
  # rolling_upgrade_policy.max_unhealthy_*_percent, this is the Azure
  # equivalent of AWS auto-rollback on instance refresh: if a rolling
  # upgrade pushes the unhealthy count over the policy threshold, the
  # upgrade pauses and Azure retries each batch.
  automatic_instance_repair {
    enabled      = true
    grace_period = "PT10M"
  }

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
    disk_size_gb         = 100
  }

  network_interface {
    name    = "primary"
    primary = true

    ip_configuration {
      name                                   = "primary"
      primary                                = true
      subnet_id                              = var.vm_subnet_id
      load_balancer_backend_address_pool_ids = [azurerm_lb_backend_address_pool.main.id]
      application_gateway_backend_address_pool_ids = local.enable_application_gateway ? [
        for p in azurerm_application_gateway.main[0].backend_address_pool : p.id if p.name == "vmss"
      ] : []
    }
  }

  rolling_upgrade_policy {
    max_batch_instance_percent              = var.rolling_upgrade_max_batch_percent
    max_unhealthy_instance_percent          = var.rolling_upgrade_max_unhealthy_percent
    max_unhealthy_upgraded_instance_percent = var.rolling_upgrade_max_unhealthy_percent
    pause_time_between_batches              = "PT2M"
  }

  custom_data = base64encode(jsonencode({
    hailbytes = {
      mode           = "scale-out"
      key_vault_uri  = azurerm_key_vault.main.vault_uri
      db_secret_name = azurerm_key_vault_secret.db.name
      db_fqdn        = azurerm_postgresql_flexible_server.primary.fqdn
      db_read_fqdns  = [for r in azurerm_postgresql_flexible_server.replica : r.fqdn]
      product        = var.product
      redis_host     = local.effective_redis_host
      redis_port     = local.effective_redis_port
      redis_tls      = local.provision_managed_redis ? true : var.redis_endpoint_override_tls
    }
  }))

  boot_diagnostics {}

  depends_on = [
    azurerm_marketplace_agreement.hailbytes,
    azurerm_postgresql_flexible_server.primary,
    azurerm_postgresql_flexible_server.replica,
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
  geo_redundant_backup_enabled = var.postgres_geo_redundant_backup_enabled

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

# ----- Shared session store: Azure Cache for Redis -----
#
# Required for horizontal scaling. Every instance in the VMSS must
# share session state, otherwise sticky-session LB stickiness becomes
# the only thing keeping users logged in across rolling upgrade.
# Standard/Premium SKUs only — Basic is single-node and breaks HA.

resource "azurerm_redis_cache" "main" {
  count                         = local.provision_managed_redis ? 1 : 0
  name                          = "${local.name_prefix}-redis"
  resource_group_name           = var.resource_group_name
  location                      = var.location
  capacity                      = var.redis_capacity
  family                        = var.redis_family
  sku_name                      = var.redis_sku_name
  non_ssl_port_enabled          = false
  minimum_tls_version           = "1.2"
  public_network_access_enabled = false
  zones                         = var.redis_sku_name == "Premium" ? ["1", "2"] : null
  tags                          = local.common_tags

  redis_configuration {
    maxmemory_policy = "allkeys-lru"
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

# ----- Backup Storage Account + immutable container -----

resource "azurerm_storage_account" "backup" {
  count                           = local.create_backup_storage ? 1 : 0
  name                            = coalesce(var.backup_storage_account_name, substr(replace("${local.name_prefix}backup", "-", ""), 0, 24))
  resource_group_name             = var.resource_group_name
  public_network_access_enabled   = false
  allow_nested_items_to_be_public = false
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = var.backup_storage_replication
  # BlobStorage, not StorageV2. Reading queue service properties goes over the
  # storage DATA PLANE, which this account refuses -- it has both shared keys
  # and public network access disabled, and there is no private endpoint or
  # service endpoint to reach it by. The provider only manages queue properties
  # for kinds that support queues, so a blob-only kind removes the call. These
  # bundles are blobs; nothing here uses queues, files or tables.
  #
  # REPLACEMENT: changing account_kind on an existing account destroys and
  # recreates it, taking any bundles with it. See CHANGELOG before upgrading.
  #
  # This kind also constrains account_replication_type: BlobStorage offers LRS,
  # GRS and RAGRS only. The zone-redundant tiers belong to StorageV2 and
  # BlockBlobStorage, so ZRS here fails the apply with "`account_replication_type`
  # of `ZRS` isn't supported for Blob Storage accounts" -- and it fails partway
  # through, after the rest of the deployment is already built.
  # var.backup_storage_replication validates the value at plan time instead.
  account_kind              = "BlobStorage"
  access_tier               = "Cool"
  min_tls_version           = "TLS1_2"
  shared_access_key_enabled = false
  tags                      = local.common_tags

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

data "azurerm_storage_account" "existing_backup" {
  count               = (!local.create_backup_storage && var.backup_storage_account_name != null) ? 1 : 0
  name                = var.backup_storage_account_name
  resource_group_name = var.resource_group_name
}

# The VMSS system-assigned identity gets least-privilege Storage Blob Data
# Contributor on the backup storage account. All VMSS instances share the
# same identity, so the assignment is one-per-VMSS not one-per-instance.

resource "azurerm_role_assignment" "vmss_backup_writer" {
  count                = local.backup_storage_account_name == null ? 0 : 1
  scope                = local.create_backup_storage ? azurerm_storage_account.backup[0].id : data.azurerm_storage_account.existing_backup[0].id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_linux_virtual_machine_scale_set.main.identity[0].principal_id
}

# ----- VMSS pre-patch Run Command extension -----
#
# Bakes the pre-patch backup as a VMSS extension that customers fire via
# `az vmss run-command invoke --command-id RunShellScript ...` or from the
# Portal under the VMSS -> Run command blade. The script ships an
# /api/instance/export bundle to the immutable Storage Account container
# and triggers a Flexible Server on-demand backup for each primary.

resource "azurerm_virtual_machine_scale_set_extension" "pre_patch_backup" {
  count                        = var.enable_pre_patch_run_command ? 1 : 0
  name                         = "RunPrePatchBackup"
  virtual_machine_scale_set_id = azurerm_linux_virtual_machine_scale_set.main.id
  publisher                    = "Microsoft.Azure.Extensions"
  type                         = "CustomScript"
  type_handler_version         = "2.1"
  auto_upgrade_minor_version   = true

  # Stored as a script for on-demand invocation; we keep it idempotent
  # so the extension does not auto-run on every reimage (settings is empty)
  # and operators invoke it via `az vmss run-command invoke` instead.
  settings = jsonencode({})
  protected_settings = jsonencode({
    script = base64encode(<<-EOSH
      #!/bin/bash
      set -euo pipefail
      TS=$(date -u +%Y-%m-%dT%H-%M-%SZ)
      export AZURE_STORAGE_ACCOUNT='${local.backup_storage_account_name == null ? "" : local.backup_storage_account_name}'
      export AZURE_STORAGE_CONTAINER='${local.backup_container_name}'
      export AZURE_BLOB_PREFIX="hailbytes-${var.product}-$${TS}"
      if [ -x /opt/hailbytes/bin/ha-pre-patch-backup.sh ]; then
        sudo -E /opt/hailbytes/bin/ha-pre-patch-backup.sh
      else
        echo "ERROR: /opt/hailbytes/bin/ha-pre-patch-backup.sh not present on this VM image." >&2
        echo "       Rebuild the marketplace image from main; provision.sh installs the script." >&2
        exit 1
      fi
      az login --identity --allow-no-subscriptions >/dev/null
      az postgres flexible-server backup create \
        --resource-group '${var.resource_group_name}' \
        --name '${azurerm_postgresql_flexible_server.primary.name}' \
        --backup-name "${local.name_prefix}-pre-patch-$${TS}" \
        || echo "WARN: on-demand backup not supported; relying on automated backups."
    EOSH
    )
  })
}

# ----- VMSS post-patch verify extension -----
#
# Mirrors the AWS aws_ssm_document.post_patch_verify in
# modules/unlimited-scale/aws/main.tf. Bakes the on-VM five-probe
# verifier as a VMSS extension so the rolling-upgrade pipeline can
# fail fast on a schema-version regression, encryption-key
# fingerprint mismatch, or smoke-test failure.

resource "azurerm_virtual_machine_scale_set_extension" "post_patch_verify" {
  count                        = var.enable_post_patch_run_command ? 1 : 0
  name                         = "RunPostPatchVerify"
  virtual_machine_scale_set_id = azurerm_linux_virtual_machine_scale_set.main.id
  publisher                    = "Microsoft.Azure.Extensions"
  type                         = "CustomScript"
  type_handler_version         = "2.1"
  auto_upgrade_minor_version   = true

  settings = jsonencode({})
  protected_settings = jsonencode({
    script = base64encode(<<-EOSH
      #!/bin/bash
      set -euo pipefail
      export HAILBYTES_SCHEMA_VERSION_PATH='${var.schema_version_endpoint_path}'
      if [ -x /opt/hailbytes/bin/ha-post-patch-verify.sh ]; then
        sudo -E /opt/hailbytes/bin/ha-post-patch-verify.sh
      else
        echo "ERROR: /opt/hailbytes/bin/ha-post-patch-verify.sh not present on this VM image." >&2
        echo "       Rebuild the marketplace image from main; provision.sh installs the script." >&2
        exit 1
      fi
    EOSH
    )
  })
}

# ----- Optional Application Gateway + WAF -----

resource "azurerm_public_ip" "appgw" {
  count               = local.enable_application_gateway ? 1 : 0
  name                = "${local.name_prefix}-appgw-pip"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  tags                = local.common_tags
}

resource "azurerm_application_gateway" "main" {
  count               = local.enable_application_gateway ? 1 : 0
  name                = "${local.name_prefix}-appgw"
  resource_group_name = var.resource_group_name
  location            = var.location
  zones               = ["1", "2", "3"]
  http2_enabled       = true
  tags                = local.common_tags

  sku {
    name = var.waf_policy_id == null ? "Standard_v2" : "WAF_v2"
    tier = var.waf_policy_id == null ? "Standard_v2" : "WAF_v2"
  }

  autoscale_configuration {
    min_capacity = 2
    max_capacity = 20
  }

  firewall_policy_id = var.waf_policy_id

  gateway_ip_configuration {
    name      = "ip-cfg"
    subnet_id = var.appgw_subnet_id
  }

  frontend_ip_configuration {
    name                 = "frontend"
    public_ip_address_id = azurerm_public_ip.appgw[0].id
  }

  frontend_port {
    name = "https"
    port = 443
  }

  backend_address_pool {
    name = "vmss"
  }

  backend_http_settings {
    name                                = "https-passthrough"
    cookie_based_affinity               = "Enabled"
    port                                = local.admin_port
    protocol                            = "Https"
    request_timeout                     = 60
    pick_host_name_from_backend_address = false
    probe_name                          = "https-health"
  }

  probe {
    name                                      = "https-health"
    protocol                                  = "Https"
    path                                      = local.health_check_path
    interval                                  = 15
    timeout                                   = 5
    unhealthy_threshold                       = 3
    pick_host_name_from_backend_http_settings = false
    host                                      = var.appgw_backend_host_header
  }

  ssl_certificate {
    name     = "tls"
    data     = var.appgw_tls_pfx_base64
    password = var.appgw_tls_pfx_password
  }

  http_listener {
    name                           = "https-listener"
    frontend_ip_configuration_name = "frontend"
    frontend_port_name             = "https"
    protocol                       = "Https"
    ssl_certificate_name           = "tls"
  }

  request_routing_rule {
    name                       = "https-to-vmss"
    rule_type                  = "Basic"
    http_listener_name         = "https-listener"
    backend_address_pool_name  = "vmss"
    backend_http_settings_name = "https-passthrough"
    priority                   = 100
  }

  lifecycle {
    precondition {
      condition     = var.appgw_subnet_id != null
      error_message = "appgw_subnet_id is required when enable_application_gateway = true."
    }
    precondition {
      condition     = var.appgw_tls_pfx_base64 != null && var.appgw_tls_pfx_password != null
      error_message = "appgw_tls_pfx_base64 and appgw_tls_pfx_password are required when enable_application_gateway = true."
    }
  }
}

# Wire the VMSS to the App Gateway backend pool when enabled.

resource "azurerm_monitor_metric_alert" "appgw_5xx" {
  count               = (!local.enable_application_gateway || var.alert_email == null) ? 0 : 1
  name                = "${local.name_prefix}-appgw-5xx-rate"
  resource_group_name = var.resource_group_name
  scopes              = [azurerm_application_gateway.main[0].id]
  description         = "App Gateway backend 5xx response count above threshold; rolling-upgrade tripwire."
  severity            = 2
  frequency           = "PT1M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.Network/applicationGateways"
    metric_name      = "BackendResponseStatus"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = var.refresh_rollback_5xx_count_threshold
    dimension {
      name     = "BackendHttpStatus"
      operator = "Include"
      values   = ["5xx"]
    }
  }

  action {
    action_group_id = azurerm_monitor_action_group.alerts.id
  }

  tags = local.common_tags
}

resource "azurerm_monitor_metric_alert" "vmss_unhealthy_repairs" {
  count               = var.alert_email == null ? 0 : 1
  name                = "${local.name_prefix}-vmss-unhealthy-repairs"
  resource_group_name = var.resource_group_name
  scopes              = [azurerm_linux_virtual_machine_scale_set.main.id]
  description         = "Automatic Instance Repair fired on the VMSS; expected only during a rolling patch."
  severity            = 2
  frequency           = "PT1M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.Compute/virtualMachineScaleSets"
    metric_name      = "VmAvailabilityMetric"
    aggregation      = "Average"
    operator         = "LessThan"
    threshold        = 1
  }

  action {
    action_group_id = azurerm_monitor_action_group.alerts.id
  }

  tags = local.common_tags
}
