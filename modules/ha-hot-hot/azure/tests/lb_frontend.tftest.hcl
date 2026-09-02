# Load-balancer frontend exposure, and the WAF bypass it used to leave open.
#
# The App Gateway does NOT sit in front of this load balancer: its backend pool
# points at azurerm_network_interface.vm[*].private_ip_address, so the gateway
# and the load balancer are PARALLEL public entry points to the same
# admin_port. An operator who enables the gateway specifically to attach a WAF
# policy therefore still had a second, un-WAF-ed public route to that port, with
# no way to close it short of giving up the gateway.
#
# var.lb_frontend_public = false makes that frontend internal, leaving the
# gateway as the only public route.
#
# That works on ASM and NOT on SAT, which is why the runs below switch product.
# SAT's phishing server shares this one frontend (80 -> phish_port), and the
# gateway declares a single listener on 443 to the admin backend -- there is no
# port-80 path to the phishing server. So on SAT an internal frontend does not
# just close the admin bypass, it takes the phishing landing pages off the
# internet, which is the product's core function. On ASM
# azurerm_lb_rule.phish has count = 0 and the admin port is the only thing on
# the frontend, so the gateway really does replace it.
#
# These runs pin: the default stays public for SAT, the gateway alone does not
# change it, false does what it says on ASM, and the three combinations that
# cannot work are refused at plan time rather than producing a deployment that
# is unreachable or has lost its phishing surface.

mock_provider "azurerm" {
  mock_resource "azurerm_log_analytics_workspace" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.OperationalInsights/workspaces/mock-law" }
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

# Nobody's existing deployment should move because this input now exists.
run "default_frontend_is_public" {
  command = plan

  assert {
    condition     = length(azurerm_public_ip.lb) == 1
    error_message = "The load balancer must get its own public IP by default - the default topology has no App Gateway, so this is the only ingress."
  }

  assert {
    condition     = one([for f in azurerm_lb.main.frontend_ip_configuration : f.subnet_id]) == null
    error_message = "A public frontend must not also be given a subnet - that is what makes it internal."
  }
}

# The gateway on its own does not close the bypass: the load balancer keeps its
# public frontend, which is the behaviour that made this input necessary.
run "gateway_alone_leaves_the_lb_frontend_public" {
  command = plan

  variables {
    enable_application_gateway = true
    appgw_tls_pfx_base64       = "TU9DSw=="
    appgw_tls_pfx_password     = "mock"
  }

  assert {
    condition     = length(azurerm_public_ip.lb) == 1
    error_message = "Enabling the gateway must not silently change the load balancer's exposure - existing deployments would be altered by an upgrade."
  }

  assert {
    condition     = one([for f in azurerm_lb.main.frontend_ip_configuration : f.subnet_id]) == null
    error_message = "With lb_frontend_public left at its default the frontend stays public even behind the gateway."
  }
}

# The point of the input, on the product that can use it.
run "internal_frontend_removes_the_public_route" {
  command = plan

  variables {
    product                    = "asm"
    enable_application_gateway = true
    appgw_tls_pfx_base64       = "TU9DSw=="
    appgw_tls_pfx_password     = "mock"
    lb_frontend_public         = false
  }

  assert {
    condition     = length(azurerm_public_ip.lb) == 0
    error_message = "An internal frontend must not create a public IP - leaving one is the bypass this input exists to close."
  }

  assert {
    condition     = one([for f in azurerm_lb.main.frontend_ip_configuration : f.subnet_id]) == var.lb_subnet_id
    error_message = "An internal frontend must take a private address in lb_subnet_id."
  }

  # The gateway must then be the only public route - and it must actually exist,
  # or the deployment has no ingress at all.
  assert {
    condition     = length(azurerm_public_ip.appgw) == 1
    error_message = "The gateway must still have its own public IP - otherwise nothing is reachable at all."
  }
}

# Without the gateway an internal frontend leaves nothing publicly reachable.
# Refuse it at plan time rather than shipping a deployment nobody can log in to.
#
# product = "asm" so that the SAT precondition below is not what fails here --
# expect_failures only asserts that azurerm_lb.main failed, not which of its
# preconditions did, so under SAT this run would pass for the wrong reason.
run "internal_frontend_without_the_gateway_is_refused" {
  command = plan

  variables {
    product            = "asm"
    lb_frontend_public = false
    # enable_application_gateway deliberately left at its default of false
  }

  expect_failures = [azurerm_lb.main]
}

# public_ip_id supplies an address for the LOAD BALANCER frontend. Asking for an
# internal frontend at the same time is a contradiction: one of the two inputs
# would have to be silently ignored.
run "internal_frontend_with_byo_public_ip_is_refused" {
  command = plan

  variables {
    product                    = "asm"
    enable_application_gateway = true
    appgw_tls_pfx_base64       = "TU9DSw=="
    appgw_tls_pfx_password     = "mock"
    lb_frontend_public         = false
    public_ip_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hailbytes-test/providers/Microsoft.Network/publicIPAddresses/byo"
  }

  expect_failures = [azurerm_lb.main]
}

# SAT's phishing landing pages ride the same frontend, on port 80, and the
# gateway has no port-80 listener. Closing the admin bypass this way would take
# the phishing surface off the internet with it, so refuse the combination -- a
# WAF on the admin console is not worth the product's core function.
run "internal_frontend_is_refused_for_sat" {
  command = plan

  variables {
    # product = "sat" from the file-level block, i.e. the default this module is
    # most often used with. Everything else here is a configuration that is
    # accepted on ASM by the run above, so the ONLY reason this fails is SAT.
    enable_application_gateway = true
    appgw_tls_pfx_base64       = "TU9DSw=="
    appgw_tls_pfx_password     = "mock"
    lb_frontend_public         = false
  }

  expect_failures = [azurerm_lb.main]
}
