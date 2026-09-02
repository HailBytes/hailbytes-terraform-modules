# Conditional resources must respect their feature flags, and the autoscale
# tier must run a zone-redundant primary plus read replicas. Plan-only checks.

mock_provider "azurerm" {
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
  product                = "asm"
  resource_group_name    = "rg-hailbytes-test"
  location               = "eastus"
  vm_subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/virtualNetworks/vnet/subnets/vm"
  db_delegated_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/virtualNetworks/vnet/subnets/db"
  private_dns_zone_id    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/privateDnsZones/test.postgres.database.azure.com"
  allowed_cidrs          = ["10.0.0.0/8"]
  admin_username         = "hbadmin"
  ssh_public_key         = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCVak/KSum8/0jr1oi9r9hvO8WDmnPqJWRRWXLOJiHcN5BuIwlNxHzn6gDP/ov7/UTpCqgrksYHojVdSj93bDnSU4Xi1X79aJ2AUxDwZZNQcPQDWS+x6kcE5q9Dv29xRIYGYgizF9thNJMfPEXVoLYeiA3aiR7UntjYkDgWfHJftrsPxqIo49A0Ep9tn4Qi5EVDRfy+rj04gKo3PCnM7qgYvGkXh4U4LRGji28VfzLkAe4rjo5ABHMRBOR3CQ2+nP1YHPBOOHK/v+ro7kOuPIItd99MhW5nP+/8TD+mJBJ9jFfkXXAqbk6E9lsOMHIuLIa5tuWV29oHo3IIVyw5V87F test@hailbytes"

  create_backup_storage_account = false
  backup_storage_account_name   = null
}

run "postgres_is_zone_redundant_with_replicas" {
  command = plan

  assert {
    condition     = azurerm_postgresql_flexible_server.primary.high_availability[0].mode == "ZoneRedundant"
    error_message = "Autoscale tier Postgres primary must be ZoneRedundant."
  }

  assert {
    condition     = length(azurerm_postgresql_flexible_server.replica) == 2
    error_message = "Default db_replica_count of 2 must create two read replicas."
  }
}

run "managed_redis_by_default" {
  command = plan

  assert {
    condition     = length(azurerm_redis_cache.main) == 1
    error_message = "Managed Redis is the autoscale default and must create one Azure Cache for Redis."
  }

  assert {
    condition     = output.redis_mode == "managed"
    error_message = "redis_mode must be 'managed' by default."
  }
}

run "redis_disabled_creates_nothing" {
  command = plan

  variables {
    enable_managed_redis = false
  }

  assert {
    condition     = length(azurerm_redis_cache.main) == 0
    error_message = "enable_managed_redis = false with no override must create zero Azure Cache for Redis instances."
  }

  assert {
    condition     = output.redis_mode == "disabled"
    error_message = "redis_mode must be 'disabled' when managed Redis is off and no override is supplied."
  }
}

run "application_gateway_off_by_default" {
  command = plan

  assert {
    condition     = length(azurerm_application_gateway.main) == 0
    error_message = "enable_application_gateway defaults to false and must create zero Application Gateways."
  }
}

run "backup_storage_not_created_when_disabled" {
  command = plan

  assert {
    condition     = length(azurerm_storage_account.backup) == 0
    error_message = "create_backup_storage_account = false must create zero backup Storage Accounts."
  }
}

# A zone-spread VMSS needs a zone-redundant frontend. A Standard public IP is
# only zone-redundant when it is created with all the region's zones; a zonal or
# no-zone public IP reintroduces the single-zone dependency the VMSS spread was
# meant to remove.
# https://learn.microsoft.com/en-us/azure/reliability/reliability-load-balancer
run "frontend_is_zone_redundant_like_the_scale_set" {
  command = plan

  assert {
    condition     = length(azurerm_public_ip.lb.zones) == 3
    error_message = "The load-balancer public IP must be zone-redundant across all three zones, or the zone-spread VMSS still has a single-zone frontend."
  }

  assert {
    condition     = length(azurerm_linux_virtual_machine_scale_set.main.zones) == 3
    error_message = "The scale set must spread across all three zones."
  }
}

# ----- SAT phishing/landing frontend -----
#
# The tier shipped with local.phish_port computed and never referenced: SAT
# autoscale deployments served no landing pages, which is the product. These
# runs pin the wiring, the ASM no-op, and the split allow-list.

run "phish_frontend_absent_on_asm" {
  command = plan

  # ASM has no phishing surface. Setting the allow-list must still open nothing:
  # the wrappers forward every core variable, so an ASM caller can pass it.
  variables {
    phish_allowed_cidrs = ["0.0.0.0/0"]
  }

  assert {
    condition     = length(azurerm_lb_rule.phish) == 0
    error_message = "ASM has no phishing surface and must create no port-80 load-balancing rule."
  }

  assert {
    condition     = length(azurerm_lb_probe.phish) == 0
    error_message = "ASM has no phishing surface and must create no phishing probe."
  }

  assert {
    condition     = length(azurerm_network_security_rule.vmss_phish_in) == 0
    error_message = "Setting phish_allowed_cidrs on ASM must open nothing on the VMSS NSG."
  }
}

run "phish_frontend_wired_on_sat" {
  command = plan

  variables {
    product = "sat"
  }

  assert {
    condition     = length(azurerm_lb_rule.phish) == 1
    error_message = "SAT must get a port-80 load-balancing rule -- landing pages and interaction tracking are the product."
  }

  assert {
    condition     = azurerm_lb_rule.phish[0].frontend_port == 80 && azurerm_lb_rule.phish[0].backend_port == 80
    error_message = "The phishing rule must front port 80 and forward to phish_port (80)."
  }

  # ha-hot-hot/azure probes phish_port over Tcp deliberately: landing pages are
  # campaign-specific and no path on the phish server is guaranteed to answer
  # 200 on a fresh deployment, so a path-based probe drains healthy instances.
  assert {
    condition     = azurerm_lb_probe.phish[0].protocol == "Tcp"
    error_message = "The phishing probe must be Tcp, not Http with a path -- a path-based probe drains a healthy fleet on a fresh deployment."
  }

  assert {
    condition     = azurerm_lb_probe.phish[0].port == 80
    error_message = "The phishing probe must probe phish_port, not the admin port."
  }

  # Two distinct probes, each on the port its own surface binds. The VMSS keeps
  # health_probe_id on the admin probe (Azure accepts one, and it is what
  # automatic_instance_repair reimages on) -- that reference is unknown at plan
  # time, but the probes themselves are not.
  assert {
    condition     = azurerm_lb_probe.https.port == 3333 && azurerm_lb_probe.phish[0].port == 80
    error_message = "SAT must probe the admin console on 3333 and the phishing surface on 80 -- separate probes, separate ports."
  }

  # The App Gateway fronts the admin console only. A WAF ruleset in front of a
  # simulated credential-harvest page blocks the very interactions the product
  # exists to record, so the phishing surface stays on the Standard LB.
  assert {
    condition = length([
      for p in azurerm_lb_rule.phish : p if p.frontend_ip_configuration_name == "frontend"
    ]) == 1
    error_message = "The phishing rule must hang off the load balancer's own frontend."
  }
}

# The admin allow-list and the phishing allow-list have opposite audiences: the
# console is for operators on an office or VPN range, the landing pages are for
# targets who are by definition somewhere else. Mirrors the ha-hot-hot/azure
# coverage added when that bug class was first fixed.
run "phish_allow_list_inherits_admin_list_by_default" {
  command = plan

  variables {
    product       = "sat"
    allowed_cidrs = ["10.0.0.0/8", "192.168.0.0/16"]
  }

  assert {
    condition     = length(azurerm_network_security_rule.vmss_phish_in) == 2
    error_message = "With phish_allowed_cidrs unset, the phishing rules must mirror allowed_cidrs one-for-one -- an existing deployment has to plan clean."
  }

  assert {
    condition = alltrue([
      for k, r in azurerm_network_security_rule.vmss_phish_in : contains(var.allowed_cidrs, r.source_address_prefix)
    ])
    error_message = "The inherited phishing rules must carry the same source prefixes as the admin rules."
  }
}

run "phish_allow_list_is_independent_when_set" {
  command = plan

  variables {
    product             = "sat"
    phish_allowed_cidrs = ["0.0.0.0/0"]
  }

  assert {
    condition = alltrue([
      for k, r in azurerm_network_security_rule.vmss_phish_in : r.source_address_prefix == "0.0.0.0/0"
    ])
    error_message = "phish_allowed_cidrs must govern the phishing frontend on its own."
  }

  assert {
    condition = alltrue([
      for k, r in azurerm_network_security_rule.vmss_https_in : r.source_address_prefix == "10.0.0.0/8"
    ])
    error_message = "Opening the phishing surface must NOT widen the admin surface -- that is the whole point of splitting the lists."
  }

  # The phishing rules must not collide with the admin rules' priority band.
  assert {
    condition = alltrue([
      for k, r in azurerm_network_security_rule.vmss_phish_in : r.priority >= 1000
    ])
    error_message = "Phishing rules must sit in their own priority band (1000+), clear of the allow-https-* rules at 100+."
  }
}
