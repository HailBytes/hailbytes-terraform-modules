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

  use_flexible_server = var.db_mode == "flexible_server"
  use_vm_db           = var.db_mode == "vm"

  db_host = local.use_flexible_server ? one(azurerm_postgresql_flexible_server.main[*].fqdn) : one(azurerm_linux_virtual_machine.db_vm[*].private_ip_address)
  db_arn  = local.use_flexible_server ? one(azurerm_postgresql_flexible_server.main[*].id) : one(azurerm_linux_virtual_machine.db_vm[*].id)

  create_backup_storage       = var.create_backup_storage_account
  backup_storage_account_name = local.create_backup_storage ? azurerm_storage_account.backup[0].name : var.backup_storage_account_name
  backup_container_name       = "hailbytes-${var.product}-bundles"

  enable_application_gateway = var.enable_application_gateway
  appgw_endpoint = local.enable_application_gateway ? azurerm_public_ip.appgw[0].ip_address : azurerm_public_ip.lb.ip_address
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
      db_mode            = var.db_mode
      key_vault_uri      = azurerm_key_vault.main.vault_uri
      db_secret_name     = azurerm_key_vault_secret.db.name
      db_fqdn            = local.db_host
      product            = var.product
      cluster_member_idx = count.index
    }
  }))

  depends_on = [
    azurerm_marketplace_agreement.hailbytes,
    azurerm_postgresql_flexible_server.main,
    azurerm_linux_virtual_machine.db_vm,
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

# ----- Postgres backend (Flexible Server in default mode; self-managed VM in 'vm' mode) -----
#
# Flexible Server is the recommended production backend. Customers who must
# keep the data plane on a Linux VM they control (compliance, simplification,
# or BYO-DBA) can flip var.db_mode = "vm" and the module provisions a third
# Standard_D2s_v5 with Postgres 16 installed via cloud-init. The Key Vault
# secret format is identical, so the SAT marketplace VHD bootstraps without
# branching.

resource "azurerm_postgresql_flexible_server" "main" {
  count               = local.use_flexible_server ? 1 : 0
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
  count     = local.use_flexible_server ? 1 : 0
  name      = "require_secure_transport"
  server_id = azurerm_postgresql_flexible_server.main[0].id
  value     = "ON"
}

resource "azurerm_postgresql_flexible_server_database" "main" {
  count     = local.use_flexible_server ? 1 : 0
  name      = "hailbytes"
  server_id = azurerm_postgresql_flexible_server.main[0].id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# Self-managed Postgres on a Linux VM (var.db_mode = "vm")

resource "azurerm_network_security_group" "db_vm" {
  count               = local.use_vm_db ? 1 : 0
  name                = "${local.name_prefix}-db-vm-nsg"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = local.common_tags
}

resource "azurerm_network_security_rule" "db_vm_pg_in" {
  count                       = local.use_vm_db ? 1 : 0
  name                        = "allow-pg-from-vmsubnet"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "5432"
  source_address_prefix       = tolist(data.azurerm_subnet.vm[0].address_prefixes)[0]
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.db_vm[0].name
}

data "azurerm_subnet" "vm" {
  count                = local.use_vm_db ? 1 : 0
  name                 = regex("subnets/([^/]+)$", var.vm_subnet_id)[0]
  virtual_network_name = regex("virtualNetworks/([^/]+)/", var.vm_subnet_id)[0]
  resource_group_name  = regex("resourceGroups/([^/]+)/", var.vm_subnet_id)[0]
}

resource "azurerm_network_interface" "db_vm" {
  count               = local.use_vm_db ? 1 : 0
  name                = "${local.name_prefix}-db-nic"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = local.common_tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = var.vm_subnet_id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_interface_security_group_association" "db_vm" {
  count                     = local.use_vm_db ? 1 : 0
  network_interface_id      = azurerm_network_interface.db_vm[0].id
  network_security_group_id = azurerm_network_security_group.db_vm[0].id
}

resource "azurerm_managed_disk" "db_data" {
  count                = local.use_vm_db ? 1 : 0
  name                 = "${local.name_prefix}-db-data"
  resource_group_name  = var.resource_group_name
  location             = var.location
  storage_account_type = "Premium_LRS"
  create_option        = "Empty"
  disk_size_gb         = var.db_vm_data_disk_size_gb
  zone                 = "1"
  tags                 = local.common_tags
}

resource "azurerm_linux_virtual_machine" "db_vm" {
  count                           = local.use_vm_db ? 1 : 0
  name                            = "${local.name_prefix}-db-vm"
  resource_group_name             = var.resource_group_name
  location                        = var.location
  size                            = var.db_vm_size
  zone                            = "1"
  admin_username                  = var.admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.db_vm[0].id]
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
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  boot_diagnostics {}

  custom_data = base64encode(<<-EOC
    #cloud-config
    package_update: true
    packages:
      - postgresql-16
      - postgresql-contrib-16
      - xfsprogs
      - jq
    write_files:
      - path: /usr/local/sbin/hailbytes-init-postgres.sh
        permissions: '0700'
        owner: root:root
        content: |
          #!/bin/bash
          set -euo pipefail
          for _ in $(seq 1 60); do
            DEV=$(lsblk -nrpo NAME,TYPE,MOUNTPOINT | awk '$2=="disk" && $3=="" {print "/dev/"$1; exit}')
            if [ -n "$DEV" ]; then break; fi
            sleep 2
          done
          : "$${DEV:?data disk did not attach within 120 seconds}"
          if ! blkid "$DEV" >/dev/null 2>&1; then mkfs.xfs "$DEV"; fi
          mkdir -p /var/lib/postgresql/16/main
          UUID=$(blkid -s UUID -o value "$DEV")
          grep -q "$$UUID" /etc/fstab || echo "UUID=$$UUID /var/lib/postgresql/16/main xfs defaults,nofail 0 2" >> /etc/fstab
          mountpoint -q /var/lib/postgresql/16/main || mount /var/lib/postgresql/16/main
          chown -R postgres:postgres /var/lib/postgresql

          systemctl stop postgresql || true
          if [ ! -s /var/lib/postgresql/16/main/PG_VERSION ]; then
            sudo -u postgres /usr/lib/postgresql/16/bin/initdb -D /var/lib/postgresql/16/main
          fi
          CONF=/etc/postgresql/16/main/postgresql.conf
          HBA=/etc/postgresql/16/main/pg_hba.conf
          grep -q "^listen_addresses" "$CONF" || echo "listen_addresses = '*'" >> "$CONF"
          grep -q "^ssl = on"          "$CONF" || echo "ssl = on"             >> "$CONF"
          grep -q "^password_encryption" "$CONF" || echo "password_encryption = scram-sha-256" >> "$CONF"
          grep -q "host hailbytes hailbytes ${tolist(data.azurerm_subnet.vm[0].address_prefixes)[0]} scram-sha-256" "$HBA" \
            || echo "host hailbytes hailbytes ${tolist(data.azurerm_subnet.vm[0].address_prefixes)[0]} scram-sha-256" >> "$HBA"
          systemctl enable postgresql
          systemctl start postgresql

          # Pull DB password from Key Vault via the VM's managed identity.
          curl -sS -H Metadata:true -m 5 "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://vault.azure.net" \
            | jq -r .access_token > /tmp/aad.token
          PW=$(curl -sS -H "Authorization: Bearer $(cat /tmp/aad.token)" \
            "${azurerm_key_vault.main.vault_uri}secrets/hailbytes-db-password?api-version=7.4" \
            | jq -r .value)
          shred -u /tmp/aad.token
          sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='hailbytes'" | grep -q 1 \
            || sudo -u postgres psql -c "CREATE USER hailbytes WITH PASSWORD '$$PW';"
          sudo -u postgres psql -c "ALTER USER hailbytes WITH PASSWORD '$$PW';"
          sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='hailbytes'" | grep -q 1 \
            || sudo -u postgres psql -c "CREATE DATABASE hailbytes OWNER hailbytes;"
    runcmd:
      - /usr/local/sbin/hailbytes-init-postgres.sh
  EOC
  )
}

resource "azurerm_virtual_machine_data_disk_attachment" "db_data" {
  count              = local.use_vm_db ? 1 : 0
  managed_disk_id    = azurerm_managed_disk.db_data[0].id
  virtual_machine_id = azurerm_linux_virtual_machine.db_vm[0].id
  lun                = 0
  caching            = "ReadWrite"
}

resource "azurerm_role_assignment" "db_vm_kv_reader" {
  count                = local.use_vm_db ? 1 : 0
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_virtual_machine.db_vm[0].identity[0].principal_id
}

# ----- Backup Storage Account + immutable container -----

data "azurerm_subscription" "current" {}

resource "azurerm_storage_account" "backup" {
  count                           = local.create_backup_storage ? 1 : 0
  name                            = coalesce(var.backup_storage_account_name, substr(replace("${local.name_prefix}backup", "-", ""), 0, 24))
  resource_group_name             = var.resource_group_name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = var.backup_storage_replication
  account_kind                    = "StorageV2"
  access_tier                     = "Cool"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  public_network_access_enabled   = true
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
        delete_after_days_since_creation          = var.backup_blob_noncurrent_expiration_days
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
  storage_container_resource_manager_id = azurerm_storage_container.backup[0].resource_manager_id
  immutability_period_in_days           = var.backup_immutability_days
  protected_append_writes_all_enabled   = false
}

data "azurerm_storage_account" "existing_backup" {
  count               = (!local.create_backup_storage && var.backup_storage_account_name != null) ? 1 : 0
  name                = var.backup_storage_account_name
  resource_group_name = var.resource_group_name
}

resource "azurerm_role_assignment" "vm_backup_writer" {
  count                = local.backup_storage_account_name == null ? 0 : local.vm_count
  scope                = local.create_backup_storage ? azurerm_storage_account.backup[0].id : data.azurerm_storage_account.existing_backup[0].id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_linux_virtual_machine.vm[count.index].identity[0].principal_id
}

# ----- Pre-patch Run Command document -----
#
# Targets the first SAT VM; the customer can run it from Azure Portal under
# Operations -> Run command -> RunPrePatchBackup. The script reads the same
# Key Vault DB secret the VM is already wired to, ships an /api/instance/export
# bundle to the immutable Storage Account container, and triggers a Flexible
# Server on-demand backup (or a managed-disk snapshot in db_mode = "vm").

resource "azurerm_virtual_machine_run_command" "pre_patch_backup" {
  count              = var.enable_pre_patch_run_command ? 1 : 0
  name               = "RunPrePatchBackup"
  location           = var.location
  virtual_machine_id = azurerm_linux_virtual_machine.vm[0].id

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
      az login --identity --allow-no-subscriptions >/dev/null
      DB_MODE='${var.db_mode}'
      if [ "$DB_MODE" = "flexible_server" ]; then
        az postgres flexible-server backup create \
          --resource-group '${var.resource_group_name}' \
          --name '${try(azurerm_postgresql_flexible_server.main[0].name, "")}' \
          --backup-name "${local.name_prefix}-pre-patch-$${TS}" \
          || echo "WARN: on-demand backup not supported on this Flexible Server tier; relying on automated backups."
      else
        az snapshot create \
          --resource-group '${var.resource_group_name}' \
          --name "${local.name_prefix}-db-pre-patch-$${TS}" \
          --source '${try(azurerm_managed_disk.db_data[0].id, "")}' \
          --incremental true \
          --tags Module=hailbytes-terraform-modules Phase=pre-patch
      fi
    EOSH
  }
}

# ----- Optional Application Gateway + WAF (procurement-grade WAF parity) -----
#
# Azure WAF requires Application Gateway (the Standard Load Balancer above is
# L4 only). Customers who want WAF parity with the AWS ALB story flip
# var.enable_application_gateway = true; the module then:
#   * provisions an App Gateway in the same vnet (var.appgw_subnet_id)
#   * fronts the LB / VMs via the App Gateway backend pool
#   * optionally attaches a customer-supplied WAF policy
# The Standard LB stays in the topology as a pure L4 backend pool member.

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
  enable_http2        = true
  tags                = local.common_tags

  sku {
    name = var.waf_policy_id == null ? "Standard_v2" : "WAF_v2"
    tier = var.waf_policy_id == null ? "Standard_v2" : "WAF_v2"
  }

  autoscale_configuration {
    min_capacity = 2
    max_capacity = 10
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
    name         = "vms"
    ip_addresses = azurerm_network_interface.vm[*].private_ip_address
  }

  backend_http_settings {
    name                  = "https-passthrough"
    cookie_based_affinity = "Enabled"
    port                  = 443
    protocol              = "Https"
    request_timeout       = 60
    pick_host_name_from_backend_address = false
    probe_name            = "https-health"
  }

  probe {
    name                = "https-health"
    protocol            = "Https"
    path                = "/health"
    interval            = 15
    timeout             = 5
    unhealthy_threshold = 3
    pick_host_name_from_backend_http_settings = false
    host                = var.appgw_backend_host_header
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
    name                       = "https-to-vms"
    rule_type                  = "Basic"
    http_listener_name         = "https-listener"
    backend_address_pool_name  = "vms"
    backend_http_settings_name = "https-passthrough"
    priority                   = 100
  }
}

# ----- Azure Monitor tripwire alerts -----

resource "azurerm_monitor_action_group" "alerts" {
  count               = var.alert_email == null ? 0 : 1
  name                = "${local.name_prefix}-ag"
  resource_group_name = var.resource_group_name
  short_name          = substr("hb${var.product}", 0, 12)
  tags                = local.common_tags

  email_receiver {
    name                    = "oncall"
    email_address           = var.alert_email
    use_common_alert_schema = true
  }
}

resource "azurerm_monitor_metric_alert" "lb_unhealthy" {
  count               = var.alert_email == null ? 0 : 1
  name                = "${local.name_prefix}-lb-unhealthy-backends"
  resource_group_name = var.resource_group_name
  scopes              = [azurerm_lb.main.id]
  description         = "LB backend pool reports unhealthy targets; expected to fire only during a rolling patch."
  severity            = 2
  frequency           = "PT1M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.Network/loadBalancers"
    metric_name      = "VipAvailability"
    aggregation      = "Average"
    operator         = "LessThan"
    threshold        = 100
  }

  action {
    action_group_id = azurerm_monitor_action_group.alerts[0].id
  }

  tags = local.common_tags
}

resource "azurerm_monitor_metric_alert" "appgw_5xx" {
  count               = (var.alert_email == null || !local.enable_application_gateway) ? 0 : 1
  name                = "${local.name_prefix}-appgw-5xx-rate"
  resource_group_name = var.resource_group_name
  scopes              = [azurerm_application_gateway.main[0].id]
  description         = "App Gateway backend 5xx response count high; rolling-patch tripwire."
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
    action_group_id = azurerm_monitor_action_group.alerts[0].id
  }

  tags = local.common_tags
}
