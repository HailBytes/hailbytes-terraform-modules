locals {

  # Load-balancer health probe path, per product.
  #
  # This was hardcoded to "/health", which matches NO route in either product:
  # SAT serves /api/health (controllers/api/server.go) and ASM serves
  # /api/ready (api/views/instance.py). A probe against a 404 never marks a
  # backend healthy, so an HA deployment comes up with an empty pool and the
  # load balancer serves 503 to every request.
  #
  # Both endpoints are unauthenticated, cheap and DB-touching, and both return
  # a non-200 when the database is unreachable, so a node that cannot serve is
  # drained rather than left in rotation.
  health_check_path = var.health_check_path != null ? var.health_check_path : (
    var.product == "sat" ? "/api/health" : "/api/ready"
  )
  # ----- Application ports -----
  #
  # Derived from var.product rather than taken as a literal default so the
  # mapping lives in exactly one place across all tiers:
  #
  #   SAT  admin UI on 3333 (config.json `listen_url`), phishing/landing on 80.
  #   ASM  Django on :8000 behind a proxy container publishing 443, so its admin
  #        surface IS 443, and it has no phishing surface.
  #
  # The wrapper defaults were the bug: asm-*-ha inherited SAT's 3333, so the
  # load balancer probed and forwarded to a port nothing on an ASM node binds.
  # The pool never went healthy and the frontend served nothing, which reads as
  # an application fault rather than a configuration one.
  admin_port = coalesce(var.admin_port, var.product == "sat" ? 3333 : 443)
  phish_port = coalesce(var.phish_port, 80)

  # Who may reach the phishing/landing surface, as opposed to the admin UI.
  #
  # These were one list. That is wrong for SAT specifically: the admin allow-list
  # is an office or VPN range, and the landing pages have to be reachable by the
  # simulation targets, who are by definition somewhere else. Sharing the list
  # means a deployment locked down correctly for the console silently serves
  # nothing to the targets -- the campaign sends, and records no interactions,
  # which reads as a product fault rather than a firewall one.
  #
  # Null inherits allowed_cidrs, so an existing deployment plans clean.
  phish_cidrs = var.phish_allowed_cidrs != null ? var.phish_allowed_cidrs : var.allowed_cidrs

  name_prefix = coalesce(var.name_prefix, "hailbytes-${var.product}-${var.environment}")

  # VM names. name_prefix governs every other resource, but the VMs themselves
  # are what a customer's host-naming policy actually constrains -- an operator
  # looking at a portal blade or a CMDB entry expects the name their standard
  # produces, not ours. `<prefix>-vm-1` satisfies nobody's convention, and it
  # cannot be coerced into one through name_prefix alone because the `-vm-N`
  # suffix is ours and the index is 1-based and unpadded.
  #
  # vm_names overrides them outright, in zone order: element 0 lands in zone 1,
  # element 1 in zone 2. Null keeps the derived names.
  vm_names = var.vm_names != null ? var.vm_names : [
    for i in range(local.vm_count) : "${local.name_prefix}-vm-${i + 1}"
  ]
  db_vm_name = coalesce(var.db_vm_name, "${local.name_prefix}-db-vm")

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

  # Customer-supplied IP wins. azurerm_public_ip.lb is behind a count, so index
  # rather than attribute-access it.
  lb_public_ip_id = var.public_ip_id != null ? var.public_ip_id : azurerm_public_ip.lb[0].id
  lb_public_ip_address = (
    var.public_ip_id != null ? data.azurerm_public_ip.supplied[0].ip_address : azurerm_public_ip.lb[0].ip_address
  )

  use_flexible_server = var.db_mode == "flexible_server"
  use_vm_db           = var.db_mode == "vm"
  use_external_db     = var.db_mode == "external"

  db_host = local.use_flexible_server ? one(azurerm_postgresql_flexible_server.main[*].fqdn) : (
    local.use_vm_db ? one(azurerm_linux_virtual_machine.db_vm[*].private_ip_address) : var.external_db_host
  )
  db_port = local.use_external_db ? var.external_db_port : 5432
  db_name = local.use_external_db ? var.external_db_name : "hailbytes"
  db_user = local.use_external_db ? var.external_db_username : "hailbytes"

  # In external mode the customer owns the server, so the password is theirs
  # rather than one we generate. It still lands in this module's Key Vault
  # under the same secret name, so the marketplace image's bootstrap path is
  # byte-identical across all three modes.
  db_password = local.use_external_db ? var.external_db_password : random_password.db.result

  create_backup_storage       = var.create_backup_storage_account
  backup_storage_account_name = local.create_backup_storage ? azurerm_storage_account.backup[0].name : var.backup_storage_account_name
  backup_container_name       = "hailbytes-${var.product}-bundles"

  enable_application_gateway = var.enable_application_gateway
  appgw_endpoint             = local.enable_application_gateway ? azurerm_public_ip.appgw[0].ip_address : local.lb_public_ip_address

  # Shared session store: required by HA SAT/ASM. Without a shared
  # Redis, both VMs fall back to in-memory sessions and the LB
  # cookie-reshuffle becomes user-visible. Default provisions an
  # Azure Cache for Redis; customers with an existing cache supply
  # var.redis_endpoint_override and set enable_managed_redis = false.
  provision_managed_redis = var.enable_managed_redis && var.redis_endpoint_override == null
  effective_redis_host    = local.provision_managed_redis ? one(azurerm_redis_cache.main[*].hostname) : var.redis_endpoint_override
  effective_redis_port    = local.provision_managed_redis ? 6380 : var.redis_endpoint_override_port

  # Azure Cache for Redis always requires an access key (or Entra auth); unlike
  # ElastiCache there is no "no-auth inside the VNet" mode. The key is written
  # to the same Key Vault as the DB password and the VMs fetch it by name.
  redis_secret_name = "hailbytes-redis-access-key"

  # Private Link for the cache. public_network_access_enabled = false means the
  # cache has no reachable endpoint at all without one, and VNet injection is a
  # Premium-tier feature, so Private Link is the only option that works on the
  # default Standard SKU. Callers composing this module with network/azure can
  # pass a shared zone; standalone deployments get one created here.
  create_redis_dns_zone   = local.provision_managed_redis && var.redis_private_dns_zone_id == null
  effective_redis_zone_id = local.provision_managed_redis ? (local.create_redis_dns_zone ? azurerm_private_dns_zone.redis[0].id : var.redis_private_dns_zone_id) : null

  effective_workspace_id = var.enable_diagnostics ? coalesce(var.log_analytics_workspace_id, one(azurerm_log_analytics_workspace.main[*].id)) : null

  # The vnet that owns vm_subnet_id, needed to link the private DNS zone.
  vm_vnet_id = regex("^(/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.Network/virtualNetworks/[^/]+)/subnets/", var.vm_subnet_id)[0]
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

# Validation for db_mode = "external". A lifecycle precondition on a
# null_resource-free anchor: random_password always exists, so this fires on
# every plan regardless of which db_mode is selected.
resource "random_password" "db" {
  lifecycle {
    precondition {
      condition     = var.db_mode != "external" || (var.external_db_host != null && var.external_db_password != null)
      error_message = "db_mode = \"external\" requires both external_db_host and external_db_password."
    }
    precondition {
      condition     = var.db_mode == "external" || (var.external_db_host == null && var.external_db_password == null)
      error_message = "external_db_host / external_db_password are only used when db_mode = \"external\"; unset them or switch db_mode."
    }
  }

  length           = 32
  special          = true
  override_special = "!@#$%^&*()-_=+"
}

resource "azurerm_role_assignment" "kv_secret_writer" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# When the apply runs as a service principal, kv_secret_writer above grants the
# vault to that principal and to nobody else. Named humans or groups get read
# access here so a credential is reachable during an incident without borrowing
# the deployment identity. Secrets User, not Officer: read, not rewrite.
resource "azurerm_role_assignment" "kv_secret_readers" {
  for_each             = toset(var.key_vault_reader_principal_ids)
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = each.value
}

# ----- Shared session keys (hailbytes-sat#907) -----
#
# Gorilla securecookie derives its hash and encryption keys per process. Two
# nodes therefore mint different keys, and a cookie minted by node A is not
# stale on node B -- it is UNDECRYPTABLE. Every de-pin becomes an unrecoverable
# logout, which is why sticky sessions cannot paper over this.
#
# One key pair per deployment, shared by both nodes, makes the default cookie
# store work across the pair with no Redis and no server-side session store:
# the session payload is a handful of scalars and travels in the cookie.
#
# random_id is stable across applies unless `keepers` changes, which matters --
# regenerating these would invalidate every live session on every apply.
resource "random_id" "session_hash_key" {
  byte_length = 32
}

resource "random_id" "session_enc_key" {
  byte_length = 32 # AES-256
}

# The initial admin password, shared by every node (hailbytes-sat#908).
#
# bootstrap.sh derives this with `openssl rand -hex 12` per VM, and models.Setup
# re-seeds it on EVERY boot while PasswordChangeRequired is still set -- which is
# deliberate on a single VM, so an operator who lost the password from the logs
# can reboot and get a fresh one. On a hot-hot pair that same behaviour means
# each node writes a DIFFERENT password to the shared database and whichever
# booted last decides which one works; a reboot re-decides it.
#
# Rather than suppress the re-seed, give both nodes the SAME value: the re-seed
# then converges instead of fighting, and the single-VM recovery property is
# untouched.
resource "random_password" "admin_initial" {
  length  = 24
  special = false # keeps the value safe in an EnvironmentFile and a shell DSN
}

resource "azurerm_key_vault_secret" "admin_initial_password" {
  name         = "hailbytes-admin-initial-password"
  value        = random_password.admin_initial.result
  key_vault_id = azurerm_key_vault.main.id

  content_type    = "application/x-hailbytes-initial-admin-password"
  expiration_date = timeadd(timestamp(), "${var.db_secret_expiration_hours}h")

  lifecycle {
    ignore_changes = [expiration_date]
  }

  depends_on = [azurerm_role_assignment.kv_secret_writer]
}

resource "azurerm_key_vault_secret" "session_keys" {
  name         = "hailbytes-session-keys"
  value        = "${random_id.session_hash_key.hex}:${random_id.session_enc_key.hex}"
  key_vault_id = azurerm_key_vault.main.id

  # Same checkov obligations as the DB secret: CKV_AZURE_114 (secret semantics)
  # and CKV_AZURE_41 (rotation deadline). Reuses db_secret_expiration_hours
  # rather than adding a second knob -- both secrets share one lifecycle, since
  # a new apply regenerates neither unless explicitly tainted.
  content_type    = "application/x-hailbytes-session-keys"
  expiration_date = timeadd(timestamp(), "${var.db_secret_expiration_hours}h")

  # Same reason as the DB secret: timestamp() would otherwise produce a
  # perpetual diff and a new secret version on every apply.
  lifecycle {
    ignore_changes = [expiration_date]
  }

  depends_on = [azurerm_role_assignment.kv_secret_writer]
}

resource "azurerm_key_vault_secret" "db" {
  name         = "hailbytes-db-password"
  value        = local.db_password
  key_vault_id = azurerm_key_vault.main.id
  # Content type satisfies CKV_AZURE_114 (identify secret semantics for
  # rotation tooling) and expiration_date satisfies CKV_AZURE_41 (every
  # secret has a rotation deadline). The expiration is intentionally
  # advisory — the password is regenerated by the module when a new
  # apply runs random_password.db; expiration is informational for KV
  # secret-rotation alerting.
  content_type    = "application/x-postgresql-password"
  expiration_date = timeadd(timestamp(), "${var.db_secret_expiration_hours}h")

  lifecycle {
    ignore_changes = [expiration_date]
  }

  depends_on = [azurerm_role_assignment.kv_secret_writer]
}

# ----- Disk encryption set (optional CMK) -----
#
# Mirrors the single-vm tier's enable_customer_managed_key option, but keys
# live in this module's own Key Vault (purge protection is already on, as
# disk encryption sets require).

resource "azurerm_role_assignment" "kv_crypto_officer" {
  count = var.enable_customer_managed_key ? 1 : 0

  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Crypto Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_key_vault_key" "disk" {
  count = var.enable_customer_managed_key ? 1 : 0

  name         = "${local.name_prefix}-disk-key"
  key_vault_id = azurerm_key_vault.main.id
  key_type     = "RSA"
  key_size     = 4096
  key_opts     = ["decrypt", "encrypt", "sign", "unwrapKey", "verify", "wrapKey"]

  depends_on = [azurerm_role_assignment.kv_crypto_officer]
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

resource "azurerm_role_assignment" "des_kv_crypto_user" {
  count = var.enable_customer_managed_key ? 1 : 0

  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Crypto Service Encryption User"
  principal_id         = azurerm_disk_encryption_set.vm[0].identity[0].principal_id
}

# CMK for the managed services — Flexible Server and the backup Storage Account
# (gap B6). Both require a *user-assigned* managed identity; neither accepts a
# system-assigned one, which is why the disk encryption set above cannot be
# reused. Microsoft's Flexible Server requirement is explicit: "Grant the Azure
# Database for PostgreSQL flexible server's user assigned managed identity
# access to the key", with the RBAC path being the Key Vault Crypto Service
# Encryption User role.
#
# The same RSA-4096 key backs disks, database and backups. One CMK per
# deployment is the normal shape — the point of CMK is that the customer can
# revoke access to their data, and one key does that for all three at once.
#
# https://learn.microsoft.com/en-us/azure/postgresql/security/security-data-encryption
resource "azurerm_user_assigned_identity" "cmk" {
  count = var.enable_customer_managed_key ? 1 : 0

  name                = "${local.name_prefix}-cmk-id"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = local.common_tags
}

resource "azurerm_role_assignment" "cmk_kv_crypto_user" {
  count = var.enable_customer_managed_key ? 1 : 0

  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Crypto Service Encryption User"
  principal_id         = azurerm_user_assigned_identity.cmk[0].principal_id
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

# The phishing frontend. Separate from the 443 rule so an operator can see, and
# revoke, the phishing surface independently of the admin surface.
resource "azurerm_network_security_rule" "lb_phish_in" {
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
  network_security_group_name = azurerm_network_security_group.lb.name
}

# Attach the NSG to the LB frontend subnet so the allow-https-* rules
# actually take effect. Without this association the rules exist on the
# NSG but the subnet routes traffic unfiltered.
resource "azurerm_subnet_network_security_group_association" "lb" {
  subnet_id                 = var.lb_subnet_id
  network_security_group_id = azurerm_network_security_group.lb.id
}

# A separate NSG for the VM subnet, created only when it differs from
# lb_subnet_id (a subnet can have exactly one associated NSG — when the
# two subnet variables point at the same subnet, azurerm_network_security_group.lb
# above already filters it). Without this, a vm_subnet_id distinct from
# lb_subnet_id got zero inbound filtering from this module: SECURITY-DEFAULTS.md
# promises "deny all inbound" but nothing enforced it for the app VMs.
resource "azurerm_network_security_group" "vm" {
  count = var.vm_subnet_id != var.lb_subnet_id ? 1 : 0

  name                = "${local.name_prefix}-vm-nsg"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = local.common_tags
}

# Azure Standard Load Balancer is a pass-through L4 device: for an inbound
# load-balancing rule it does NOT SNAT, so the backend sees the ORIGINAL CLIENT
# source IP, not the load balancer's. The AzureLoadBalancer service tag covers
# only the health-probe source (168.63.129.16) and Azure infrastructure.
#
# So admin_port has to be allowed from allowed_cidrs as well as from the probe
# tag. Allowing it from the probe tag alone is the trap: probes succeed, the
# backend pool reports healthy, the topology looks green -- and every real
# request is dropped by the NSG, which reads as an application bug rather than a
# network one.
#
# This is not a widened public surface. The VMs have no public IP of their own
# (azurerm_public_ip.lb is the only ingress), so the sole route to admin_port is
# through the load balancer's 443 frontend, which allowed_cidrs already bounds.
resource "azurerm_network_security_rule" "vm_admin_in" {
  for_each = var.vm_subnet_id != var.lb_subnet_id ? { for i, c in var.allowed_cidrs : tostring(i) => c } : {}

  name                        = "allow-admin-${each.key}"
  priority                    = 100 + tonumber(each.key)
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = tostring(local.admin_port)
  source_address_prefix       = each.value
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.vm[0].name
}

resource "azurerm_network_security_rule" "vm_phish_in" {
  for_each = var.product == "sat" && var.vm_subnet_id != var.lb_subnet_id ? { for i, c in local.phish_cidrs : tostring(i) => c } : {}

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
  network_security_group_name = azurerm_network_security_group.vm[0].name
}

# Health probes only. Without this the probe is dropped, the pool never goes
# healthy, and the frontend serves 503 no matter what the application is doing.
resource "azurerm_network_security_rule" "vm_probe_in" {
  count = var.vm_subnet_id != var.lb_subnet_id ? 1 : 0

  name              = "allow-lb-probe"
  priority          = 2000
  direction         = "Inbound"
  access            = "Allow"
  protocol          = "Tcp"
  source_port_range = "*"
  destination_port_ranges = var.product == "sat" ? [
    tostring(local.admin_port),
    tostring(local.phish_port),
  ] : [tostring(local.admin_port)]
  source_address_prefix       = "AzureLoadBalancer"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.vm[0].name
}

resource "azurerm_subnet_network_security_group_association" "vm" {
  count = var.associate_vm_subnet_nsg && var.vm_subnet_id != var.lb_subnet_id ? 1 : 0

  subnet_id                 = var.vm_subnet_id
  network_security_group_id = azurerm_network_security_group.vm[0].id
}

# ----- Load Balancer -----

# Read the address off a customer-supplied IP so load_balancer_public_ip still
# answers, rather than going empty the moment someone brings their own.
data "azurerm_public_ip" "supplied" {
  count               = var.public_ip_id != null ? 1 : 0
  name                = reverse(split("/", var.public_ip_id))[0]
  resource_group_name = split("/", var.public_ip_id)[4]
}

resource "azurerm_public_ip" "lb" {
  count               = var.public_ip_id == null ? 1 : 0
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
    public_ip_address_id = local.lb_public_ip_id
  }
}

resource "azurerm_lb_backend_address_pool" "main" {
  loadbalancer_id = azurerm_lb.main.id
  name            = "backend"
}

# The application binds admin on local.admin_port (TLS) and the phishing server
# on local.phish_port (plaintext) -- see hailbytes-sat/config.json. Nothing binds
# 443 on the backend, so both the probe and the rule have to target the real
# ports or the pool never goes healthy and the frontend serves 503.
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
  idle_timeout_in_minutes        = 4
  tcp_reset_enabled              = true
}

# The phishing and tracking surface. On SAT this carries the landing pages and
# the click/open tracking that the product exists to deliver, so an HA pair that
# only fronts the admin port is not serving the product.
#
# A Tcp probe rather than Http with a path: landing pages are campaign-specific
# and there is no path on the phish server guaranteed to return 200 on a fresh
# deployment, so a path-based probe would drain healthy nodes.
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
  idle_timeout_in_minutes        = 4
  tcp_reset_enabled              = true
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

  name                            = local.vm_names[count.index]
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
    caching                = "ReadWrite"
    storage_account_type   = "Premium_LRS"
    disk_size_gb           = 100
    disk_encryption_set_id = var.enable_customer_managed_key ? azurerm_disk_encryption_set.vm[0].id : null
  }

  # Exactly one of these two paths is live. Default (source_image_id == null) is
  # the marketplace image with its `plan` block, which is what every real
  # deployment uses and what marketplace billing keys off. See the
  # source_image_id variable for why the test-only path exists and what it gives
  # up.
  source_image_id = var.source_image_id

  dynamic "source_image_reference" {
    for_each = var.source_image_id == null ? [1] : []

    content {
      publisher = local.plan.publisher
      offer     = local.plan.offer
      sku       = local.plan.sku
      version   = local.plan.version
    }
  }

  dynamic "plan" {
    for_each = var.source_image_id == null ? [1] : []

    content {
      name      = local.plan.sku
      publisher = local.plan.publisher
      product   = local.plan.offer
    }
  }

  boot_diagnostics {}

  # This payload is what the image is SUPPOSED to consume to wire itself to the
  # shared DB. As of this commit the published marketplace image does not read
  # it at all -- see hailbytes-sat#906. Until that lands, a VM booted from the
  # marketplace image ignores every field below and comes up on its own local
  # Postgres, which is a split-brain pair, not an HA pair. Do not read the
  # presence of this block as evidence the wiring works.
  #
  # Redis is NOT required for HA. The session payload is a handful of scalars,
  # so shared hash/encryption keys alone make the default cookie store work
  # across nodes (hailbytes-sat#907); Redis is an optimisation.
  custom_data = base64encode(jsonencode({
    hailbytes = {
      mode           = "ha"
      db_mode        = var.db_mode
      key_vault_uri  = azurerm_key_vault.main.vault_uri
      db_secret_name = azurerm_key_vault_secret.db.name
      # Shared session keys, "<hash hex>:<enc hex>". Both nodes read the same
      # secret so a cookie minted on one is decryptable on the other.
      session_keys_secret_name = azurerm_key_vault_secret.session_keys.name
      # Shared initial admin password, so the per-boot re-seed converges on one
      # value across nodes instead of the last node to boot winning.
      admin_password_secret_name = azurerm_key_vault_secret.admin_initial_password.name
      db_fqdn                    = local.db_host
      db_port                    = local.db_port
      db_name                    = local.db_name
      db_user                    = local.db_user
      db_sslmode                 = local.use_external_db ? var.external_db_sslmode : "require"
      product                    = var.product
      cluster_member_idx         = count.index
      redis_host                 = local.effective_redis_host
      redis_port                 = local.effective_redis_port
      redis_tls                  = local.provision_managed_redis ? true : var.redis_endpoint_override_tls
      # Azure Cache for Redis requires an access key. The VM reads it from the
      # same Key Vault as the DB password; only the secret name travels here.
      redis_secret_name = local.provision_managed_redis ? local.redis_secret_name : null
    }
  }))

  # Both attributes force replacement, and `count` means a single apply would
  # replace BOTH app VMs at once — a full outage of a topology whose entire
  # purpose is not having one. marketplace_image_version defaults to "latest",
  # so an unrelated apply (a tag change, a new allowed CIDR) picks up whatever
  # version Microsoft published since and takes the deployment down without the
  # operator ever asking for an upgrade.
  #
  # Image rotation is therefore explicit and one VM at a time:
  #   terraform apply -replace='module.sat.azurerm_linux_virtual_machine.vm[0]'
  # which is exactly the rolling procedure in docs/AZURE_PATCHING_AND_MIGRATION.md.
  # This mirrors ignore_changes = [ami, user_data] on the AWS side.
  lifecycle {
    ignore_changes = [source_image_reference, custom_data]
  }

  depends_on = [
    azurerm_marketplace_agreement.hailbytes,
    azurerm_postgresql_flexible_server.main,
    azurerm_linux_virtual_machine.db_vm,
    azurerm_redis_cache.main,
    azurerm_role_assignment.des_kv_crypto_user,
  ]
}

# The app VMs' managed identities must be able to read the DB password (and
# the Redis key) from Key Vault — custom_data points them at the vault, but
# the vault is rbac_authorization_enabled so without this role assignment they
# get 403 and the deployment cannot start. This is the Azure counterpart of
# aws_iam_role_policy.secrets in the AWS module.
resource "azurerm_role_assignment" "vm_kv_secrets_user" {
  count = local.vm_count

  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_virtual_machine.vm[count.index].identity[0].principal_id
}

resource "azurerm_managed_disk" "data" {
  count = local.vm_count

  name                   = "${local.name_prefix}-data-${count.index + 1}"
  resource_group_name    = var.resource_group_name
  location               = var.location
  storage_account_type   = "Premium_LRS"
  create_option          = "Empty"
  disk_size_gb           = var.data_disk_size_gb
  zone                   = local.vm_zones[count.index]
  disk_encryption_set_id = var.enable_customer_managed_key ? azurerm_disk_encryption_set.vm[0].id : null
  tags                   = local.common_tags

  depends_on = [azurerm_role_assignment.des_kv_crypto_user]
}

resource "azurerm_virtual_machine_data_disk_attachment" "data" {
  count = local.vm_count

  managed_disk_id    = azurerm_managed_disk.data[count.index].id
  virtual_machine_id = azurerm_linux_virtual_machine.vm[count.index].id
  lun                = 0
  caching            = "ReadWrite"
}

# ----- Shared session store: Azure Cache for Redis (zone-redundant) -----
#
# HA SAT/ASM require a shared Redis endpoint for cross-instance sessions
# and the worker-lock heartbeat. Without it both VMs fall back to
# in-memory sessions and the LB's cookie reshuffle becomes a user-
# visible logout. Equivalent to AWS ElastiCache; the asm-aws-ha and
# sat-aws-ha modules provision the same shape with the same defaults.

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
  # Standard gives a primary/replica pair, but BOTH nodes sit in one zone:
  # Azure offers zone redundancy for this service on Premium and above only,
  # which is why `zones` is set for Premium and null otherwise. An earlier
  # version of this comment called Standard "Multi-AZ". It is not, and on a
  # tier whose entire purpose is surviving a zone loss the distinction is the
  # whole point -- see the enable_managed_redis variable for what that costs
  # you and why the cheapest correct answer may be to turn the cache off.
  zones = var.redis_sku_name == "Premium" ? ["1", "2"] : null
  tags  = local.common_tags

  redis_configuration {
    maxmemory_policy = "allkeys-lru"
  }
}

# ----- Redis reachability: Private Link -----
#
# Without this the cache is provisioned but unreachable: the module sets
# public_network_access_enabled = false, and VNet injection needs Premium.
# Private Link works on Standard, so this is what makes the default SKU usable.

resource "azurerm_private_dns_zone" "redis" {
  count = local.create_redis_dns_zone ? 1 : 0

  name                = "privatelink.redis.cache.windows.net"
  resource_group_name = var.resource_group_name
  tags                = local.common_tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "redis" {
  count = local.create_redis_dns_zone ? 1 : 0

  name                  = "${local.name_prefix}-redis-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.redis[0].name
  virtual_network_id    = local.vm_vnet_id
  registration_enabled  = false
  tags                  = local.common_tags
}

resource "azurerm_private_endpoint" "redis" {
  count = local.provision_managed_redis ? 1 : 0

  name                = "${local.name_prefix}-redis-pe"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = coalesce(var.redis_private_endpoint_subnet_id, var.vm_subnet_id)
  tags                = local.common_tags

  private_service_connection {
    name                           = "${local.name_prefix}-redis-psc"
    private_connection_resource_id = azurerm_redis_cache.main[0].id
    subresource_names              = ["redisCache"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "redis"
    private_dns_zone_ids = [local.effective_redis_zone_id]
  }
}

# The access key the VMs authenticate with, alongside the DB password in the
# same vault. Rotating the cache regenerates the key; re-running apply
# refreshes this secret.
resource "azurerm_key_vault_secret" "redis" {
  count = local.provision_managed_redis ? 1 : 0

  name            = local.redis_secret_name
  value           = azurerm_redis_cache.main[0].primary_access_key
  key_vault_id    = azurerm_key_vault.main.id
  content_type    = "application/x-redis-access-key"
  expiration_date = timeadd(timestamp(), "${var.db_secret_expiration_hours}h")

  lifecycle {
    ignore_changes = [expiration_date]
  }

  depends_on = [azurerm_role_assignment.kv_secret_writer]
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
  administrator_password = random_password.db.result # never local.db_password: external mode creates no server

  delegated_subnet_id = var.db_delegated_subnet_id
  private_dns_zone_id = var.private_dns_zone_id

  backup_retention_days        = var.db_backup_retention_days
  geo_redundant_backup_enabled = var.postgres_geo_redundant_backup_enabled

  high_availability {
    mode = var.db_high_availability_mode
  }

  # CMK (gap B6). Two Microsoft constraints shape this block:
  #
  # 1. "You can configure customer managed key encryption only during creation
  #    of a new server, not as an update to an existing" server — and it cannot
  #    be reverted either. So flipping enable_customer_managed_key on an
  #    existing deployment REPLACES the database. See the precondition below.
  # 2. The key URI is deliberately versionless (versionless_id, not id). With a
  #    versioned URI the server pins to that version and goes Inaccessible when
  #    it expires; versionless enables automatic key version updates, which is
  #    what Microsoft recommends and what makes Key Vault autorotation safe.
  dynamic "identity" {
    for_each = var.enable_customer_managed_key ? [1] : []
    content {
      type         = "UserAssigned"
      identity_ids = [azurerm_user_assigned_identity.cmk[0].id]
    }
  }

  dynamic "customer_managed_key" {
    for_each = var.enable_customer_managed_key ? [1] : []
    content {
      key_vault_key_id                  = azurerm_key_vault_key.disk[0].versionless_id
      primary_user_assigned_identity_id = azurerm_user_assigned_identity.cmk[0].id
    }
  }

  tags = local.common_tags

  lifecycle {
    ignore_changes = [administrator_password, zone, high_availability[0].standby_availability_zone]

    # Geo-redundant backup with CMK needs a SECOND key, in a second Key Vault,
    # in the geo-paired region, reached by a SECOND user-assigned identity that
    # Microsoft documents cannot be the same one: "You can't use the same
    # user-managed identity to authenticate for the primary database's Key Vault
    # instance and the Key Vault instance that holds the encryption key for
    # geo-redundant backup." This module provisions one vault in one region, so
    # the combination is refused at plan time rather than failing mid-apply.
    precondition {
      condition     = !(var.enable_customer_managed_key && var.postgres_geo_redundant_backup_enabled)
      error_message = "enable_customer_managed_key and postgres_geo_redundant_backup_enabled cannot both be set: Azure requires a separate key, Key Vault and user-assigned identity in the geo-paired region for the geo-backup, which this module does not provision. Pick one, or supply the geo-region key vault yourself outside the module."
    }
  }

  depends_on = [azurerm_role_assignment.cmk_kv_crypto_user]
}

resource "azurerm_postgresql_flexible_server_configuration" "require_ssl" {
  count     = local.use_flexible_server ? 1 : 0
  name      = "require_secure_transport"
  server_id = azurerm_postgresql_flexible_server.main[0].id
  value     = "ON"
}

# Slow-query logging, the Azure counterpart of the AWS parameter group's
# log_min_duration_statement (gap C4). Without it the diagnostic setting added
# for B2 ships PostgreSQLLogs to Log Analytics with nothing interesting in them:
# Flexible Server's default is -1, which logs no statement durations at all.
# 1000 ms matches the AWS side so a triage runbook reads the same on both
# clouds.
resource "azurerm_postgresql_flexible_server_configuration" "log_min_duration_statement" {
  count     = local.use_flexible_server ? 1 : 0
  name      = "log_min_duration_statement"
  server_id = azurerm_postgresql_flexible_server.main[0].id
  value     = tostring(var.db_log_min_duration_ms)
}

# Deletion protection. Azure has no `deletion_protection` argument on Flexible
# Server the way RDS does, so a CanNotDelete management lock is the equivalent —
# it blocks deletion of the server (and its backups) by anyone, including the
# operator running `terraform destroy`, until the lock is removed.
#
# Off by default *because* it is effective: with the lock in place
# `terraform destroy` fails partway through and leaves a half-destroyed stack,
# which is a worse first experience for a PoC than an accidental delete. Turn it
# on for production, and remove it deliberately before a planned teardown:
#   terraform apply -var='enable_db_delete_lock=false' && terraform destroy
resource "azurerm_management_lock" "db" {
  count      = local.use_flexible_server && var.enable_db_delete_lock ? 1 : 0
  name       = "${local.name_prefix}-pg-no-delete"
  scope      = azurerm_postgresql_flexible_server.main[0].id
  lock_level = "CanNotDelete"
  notes      = "HailBytes ${var.product} database. Remove this lock deliberately before a planned teardown; see enable_db_delete_lock."
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
  count                  = local.use_vm_db ? 1 : 0
  name                   = "${local.name_prefix}-db-data"
  resource_group_name    = var.resource_group_name
  location               = var.location
  storage_account_type   = "Premium_LRS"
  create_option          = "Empty"
  disk_size_gb           = var.db_vm_data_disk_size_gb
  zone                   = "1"
  disk_encryption_set_id = var.enable_customer_managed_key ? azurerm_disk_encryption_set.vm[0].id : null
  tags                   = local.common_tags

  depends_on = [azurerm_role_assignment.des_kv_crypto_user]
}

resource "azurerm_linux_virtual_machine" "db_vm" {
  count                           = local.use_vm_db ? 1 : 0
  name                            = local.db_vm_name
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
    caching                = "ReadWrite"
    storage_account_type   = "Premium_LRS"
    disk_size_gb           = 30
    disk_encryption_set_id = var.enable_customer_managed_key ? azurerm_disk_encryption_set.vm[0].id : null
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

  # source_image_reference.version is "latest" here too, and this VM holds the
  # database on an attached data disk. An implicit replacement would detach the
  # disk and re-run initdb's guard against a volume that already has a cluster
  # on it — recoverable, but only after an outage nobody scheduled. Ubuntu
  # security patching happens in-guest via unattended-upgrades, not by replacing
  # the VM. Mirrors ignore_changes = [ami, user_data] on aws_instance.db_ec2.
  lifecycle {
    ignore_changes = [source_image_reference, custom_data]
  }

  depends_on = [azurerm_role_assignment.des_kv_crypto_user]
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

  # CMK for the pre-patch backup bundles (gap B6). Unlike Flexible Server this
  # one is switchable on an existing account — Azure Storage rewraps the account
  # DEK with the new key and the data stays encrypted throughout — so no
  # precondition is needed here.
  dynamic "identity" {
    for_each = var.enable_customer_managed_key ? [1] : []
    content {
      type         = "UserAssigned"
      identity_ids = [azurerm_user_assigned_identity.cmk[0].id]
    }
  }

  dynamic "customer_managed_key" {
    for_each = var.enable_customer_managed_key ? [1] : []
    content {
      key_vault_key_id          = azurerm_key_vault_key.disk[0].versionless_id
      user_assigned_identity_id = azurerm_user_assigned_identity.cmk[0].id
    }
  }

  depends_on = [azurerm_role_assignment.cmk_kv_crypto_user]
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

      # The script needs libpq coordinates and a password, or it exits 1 before
      # pg_dump runs. The password comes from the same Key Vault secret the app
      # reads, via this VM's managed identity.
      export HAILBYTES_SAT_DB_HOST='${local.db_host}'
      export HAILBYTES_SAT_DB_PORT='${local.db_port}'
      export HAILBYTES_SAT_DB_USER='${local.db_user}'
      export HAILBYTES_SAT_DB_NAME='${local.db_name}'
      KV_TOKEN=$(curl -sS -H Metadata:true -m 10 \
        "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://vault.azure.net" \
        | jq -r .access_token)
      if [ -z "$KV_TOKEN" ] || [ "$KV_TOKEN" = "null" ]; then
        echo "ERROR: could not obtain a managed-identity token for Key Vault." >&2
        exit 1
      fi
      PGPASSWORD=$(curl -sS -m 10 -H "Authorization: Bearer $KV_TOKEN" \
        "${azurerm_key_vault.main.vault_uri}secrets/${azurerm_key_vault_secret.db.name}?api-version=7.4" \
        | jq -r .value)
      if [ -z "$PGPASSWORD" ] || [ "$PGPASSWORD" = "null" ]; then
        echo "ERROR: could not read the DB password from Key Vault. Confirm this VM's" >&2
        echo "       identity holds the Key Vault Secrets User role on the vault." >&2
        exit 1
      fi
      export PGPASSWORD
      unset KV_TOKEN

      if [ -x /opt/hailbytes/bin/ha-pre-patch-backup.sh ]; then
        sudo -E /opt/hailbytes/bin/ha-pre-patch-backup.sh
      else
        echo "ERROR: /opt/hailbytes/bin/ha-pre-patch-backup.sh not present on this VM image." >&2
        echo "       Rebuild the marketplace image from main; provision.sh installs the script." >&2
        exit 1
      fi
      DB_MODE='${var.db_mode}'
      if [ "$DB_MODE" = "external" ]; then
        echo "NOTE: db_mode=external — the database is customer-managed, so this"
        echo "      Run Command takes no server-side snapshot. Ensure your own"
        echo "      backup or PITR covers the patch window before proceeding."
        exit 0
      fi
      az login --identity --allow-no-subscriptions >/dev/null
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

# ----- Post-patch verify Run Command -----
#
# Mirrors the AWS aws_ssm_document.post_patch_verify in
# modules/ha-hot-hot/aws/main.tf. Customers run this from Azure Portal
# under Operations -> Run command -> RunPostPatchVerify after each VM
# comes back from an image swap, before draining the second VM.

resource "azurerm_virtual_machine_run_command" "post_patch_verify" {
  count              = var.enable_post_patch_run_command ? local.vm_count : 0
  name               = "RunPostPatchVerify"
  location           = var.location
  virtual_machine_id = azurerm_linux_virtual_machine.vm[count.index].id

  source {
    script = <<-EOSH
      #!/bin/bash
      set -euo pipefail
      export HAILBYTES_SCHEMA_VERSION_PATH='${var.schema_version_endpoint_path}'
      # The verifier takes the admin host as a positional argument and exits 1
      # on the usage check without one. Running on-box, that is localhost.
      if [ -x /opt/hailbytes/bin/ha-post-patch-verify.sh ]; then
        sudo -E /opt/hailbytes/bin/ha-post-patch-verify.sh 127.0.0.1 ${local.admin_port}
      else
        echo "ERROR: /opt/hailbytes/bin/ha-post-patch-verify.sh not present on this VM image." >&2
        echo "       Rebuild the marketplace image from main; provision.sh installs the script." >&2
        exit 1
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
  http2_enabled       = true
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

  # Backend hop. See the A6 note in docs/AZURE_HA_PARITY_AUDIT.md: App Gateway
  # v2 validates the backend certificate. Per Microsoft's end-to-end TLS
  # documentation, a self-signed backend certificate — which is exactly what the
  # marketplace image generates on first boot — requires its root uploaded as a
  # trusted root certificate, AND the backend settings' host must match the
  # certificate's CN. Without both, the gateway marks the pool unhealthy and
  # returns 502. var.appgw_backend_protocol = "Http" is the other supported
  # path: terminate TLS at the gateway and use the private VNet hop in clear.
  backend_http_settings {
    name                                = "backend"
    cookie_based_affinity               = "Enabled"
    port                                = var.appgw_backend_port
    protocol                            = var.appgw_backend_protocol
    request_timeout                     = 60
    pick_host_name_from_backend_address = false
    host_name                           = var.appgw_backend_host_header
    probe_name                          = "backend-health"

    trusted_root_certificate_names = (
      var.appgw_backend_protocol == "Https" && var.appgw_backend_root_cert_pem != null
    ) ? ["backend-root"] : []
  }

  dynamic "trusted_root_certificate" {
    for_each = var.appgw_backend_protocol == "Https" && var.appgw_backend_root_cert_pem != null ? [1] : []
    content {
      name = "backend-root"
      data = var.appgw_backend_root_cert_pem
    }
  }

  probe {
    name                                      = "backend-health"
    protocol                                  = var.appgw_backend_protocol
    path                                      = local.health_check_path
    interval                                  = 15
    timeout                                   = 5
    unhealthy_threshold                       = 3
    pick_host_name_from_backend_http_settings = true
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

  lifecycle {
    precondition {
      condition     = var.appgw_subnet_id != null
      error_message = "appgw_subnet_id is required when enable_application_gateway = true."
    }
    precondition {
      condition     = var.appgw_tls_pfx_base64 != null && var.appgw_tls_pfx_password != null
      error_message = "appgw_tls_pfx_base64 and appgw_tls_pfx_password are required when enable_application_gateway = true."
    }
    # Application Gateway v2 validates the backend certificate: a self-signed
    # or unknown-CA backend needs its root uploaded, and the backend host must
    # match the certificate CN. Refuse to build a topology Microsoft documents
    # as returning 502 rather than shipping it and letting the customer find
    # out during a patch window.
    precondition {
      condition = var.appgw_backend_protocol != "Https" || (
        var.appgw_backend_root_cert_pem != null && var.appgw_backend_host_header != null
      )
      error_message = <<-EOM
        appgw_backend_protocol = "Https" needs BOTH appgw_backend_root_cert_pem
        and appgw_backend_host_header. Application Gateway v2 validates the
        backend certificate against an uploaded trusted root and checks that the
        backend host matches the certificate's CN; without both it marks the
        pool unhealthy and serves 502.

        The marketplace image generates a self-signed certificate on first boot
        with CN "hailbytes-sat-admin", so either:
          * set appgw_backend_root_cert_pem to that certificate (it is its own
            root) and appgw_backend_host_header = "hailbytes-sat-admin"; or
          * set appgw_backend_protocol = "Http" to terminate TLS at the gateway
            and use the private VNet hop in clear.
      EOM
    }
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

# ----- Observability: diagnostic settings (gap B2) -----
#
# The AWS module ships optional ALB access logs to a versioned, lifecycled S3
# bucket; SECURITY-DEFAULTS.md claimed the Azure equivalent existed. It did
# not — there was no azurerm_monitor_diagnostic_setting anywhere in the Azure
# modules, and no destination for one. This sends the load balancer, the
# database and (when enabled) the Application Gateway to a Log Analytics
# workspace, which is where an Azure security reviewer expects to find them.

resource "azurerm_log_analytics_workspace" "main" {
  count = var.enable_diagnostics && var.log_analytics_workspace_id == null ? 1 : 0

  name                = "${local.name_prefix}-law"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = var.diagnostics_retention_days
  tags                = local.common_tags
}

resource "azurerm_monitor_diagnostic_setting" "lb" {
  count = var.enable_diagnostics ? 1 : 0

  name                       = "${local.name_prefix}-lb-diag"
  target_resource_id         = azurerm_lb.main.id
  log_analytics_workspace_id = local.effective_workspace_id

  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_diagnostic_setting" "postgres" {
  count = var.enable_diagnostics && local.use_flexible_server ? 1 : 0

  name                       = "${local.name_prefix}-pg-diag"
  target_resource_id         = azurerm_postgresql_flexible_server.main[0].id
  log_analytics_workspace_id = local.effective_workspace_id

  enabled_log {
    category = "PostgreSQLLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_diagnostic_setting" "redis" {
  count = var.enable_diagnostics && local.provision_managed_redis ? 1 : 0

  name                       = "${local.name_prefix}-redis-diag"
  target_resource_id         = azurerm_redis_cache.main[0].id
  log_analytics_workspace_id = local.effective_workspace_id

  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_diagnostic_setting" "appgw" {
  count = var.enable_diagnostics && local.enable_application_gateway ? 1 : 0

  name                       = "${local.name_prefix}-appgw-diag"
  target_resource_id         = azurerm_application_gateway.main[0].id
  log_analytics_workspace_id = local.effective_workspace_id

  # The closest Azure analogue of ALB access logs. Only the App Gateway has
  # request-level logs; a Standard Load Balancer is L4 and has none, which is
  # worth knowing before promising "LB access logs" to a reviewer.
  enabled_log {
    category = "ApplicationGatewayAccessLog"
  }

  enabled_log {
    category = "ApplicationGatewayFirewallLog"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

# ----- Break-glass management access (gap B3) -----
#
# SECURITY-DEFAULTS.md promised "Modules wire these up when
# enable_management_access = true" and named Azure Bastion. Nothing did. The
# AAD-login extension is the lighter-weight half of that promise: it gives
# Entra-authenticated, RBAC-gated SSH without a public IP and without the
# ~$140/month a Bastion host costs, and it pairs with `az ssh vm`.
resource "azurerm_virtual_machine_extension" "aad_ssh_login" {
  count = var.enable_management_access ? local.vm_count : 0

  name                       = "AADSSHLoginForLinux"
  virtual_machine_id         = azurerm_linux_virtual_machine.vm[count.index].id
  publisher                  = "Microsoft.Azure.ActiveDirectory"
  type                       = "AADSSHLoginForLinux"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
  tags                       = local.common_tags
}
