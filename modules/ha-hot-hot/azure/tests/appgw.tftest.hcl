# Application Gateway backend-TLS contract (gap A6).
#
# Microsoft's end-to-end TLS documentation is explicit: Application Gateway v2
# "only communicates with backends whose server certificate's root certificate
# matches one of the list of trusted root certificates in the backend http
# setting", and it "validates if the Host setting specified in the backend http
# setting matches that of the common name (CN) presented by the backend
# server's TLS/SSL certificate". A self-signed backend — which is what the
# marketplace image generates on first boot — satisfies neither by default, so
# the gateway marks the pool unhealthy and serves 502.
#
# The module previously shipped exactly that configuration: protocol = "Https",
# no trusted root, host defaulting to null. These runs pin the contract so it
# cannot regress, and prove the precondition refuses the broken combination at
# plan time rather than at a customer's patch window.
#
# https://learn.microsoft.com/en-us/azure/application-gateway/ssl-overview

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

  enable_application_gateway = true
  appgw_tls_pfx_base64       = "TU9DSw=="
  appgw_tls_pfx_password     = "mock"
}

# The default backend hop terminates TLS at the gateway. That needs no backend
# certificate trust, so it must plan cleanly with no extra inputs.
run "default_backend_hop_is_http_and_needs_no_cert_trust" {
  command = plan

  assert {
    condition     = one([for b in azurerm_application_gateway.main[0].backend_http_settings : b.protocol]) == "Http"
    error_message = "The default backend hop must be Http: an Https hop to the image's self-signed certificate is documented to 502."
  }

  assert {
    condition     = length(azurerm_application_gateway.main[0].trusted_root_certificate) == 0
    error_message = "No trusted root certificate should be uploaded when the backend hop is Http."
  }

  assert {
    condition     = one([for pr in azurerm_application_gateway.main[0].probe : pr.protocol]) == "Http"
    error_message = "The health probe must use the same protocol as the backend hop, or it validates something the data path does not."
  }
}

# End-to-end TLS is available, but only in the configuration Microsoft
# documents as working.
run "https_backend_hop_uploads_the_trusted_root" {
  command = plan

  variables {
    appgw_backend_protocol      = "Https"
    appgw_backend_port          = 443
    appgw_backend_host_header   = "hailbytes-sat-admin"
    appgw_backend_root_cert_pem = "-----BEGIN CERTIFICATE-----\nTU9DSw==\n-----END CERTIFICATE-----"
  }

  assert {
    condition     = length(azurerm_application_gateway.main[0].trusted_root_certificate) == 1
    error_message = "An Https backend hop must upload the backend's root certificate as a trusted root."
  }

  assert {
    condition     = contains(one([for b in azurerm_application_gateway.main[0].backend_http_settings : b.trusted_root_certificate_names]), "backend-root")
    error_message = "The backend settings must reference the uploaded trusted root, or the gateway will not trust the backend."
  }

  assert {
    condition     = one([for b in azurerm_application_gateway.main[0].backend_http_settings : b.host_name]) == "hailbytes-sat-admin"
    error_message = "The backend host must be set so App Gateway can match it against the backend certificate's CN."
  }
}

# The whole point of the precondition: reject the combination that 502s.
run "https_backend_hop_without_root_cert_is_refused" {
  command = plan

  variables {
    appgw_backend_protocol    = "Https"
    appgw_backend_port        = 443
    appgw_backend_host_header = "hailbytes-sat-admin"
    # appgw_backend_root_cert_pem deliberately omitted
  }

  expect_failures = [azurerm_application_gateway.main]
}

run "https_backend_hop_without_host_header_is_refused" {
  command = plan

  variables {
    appgw_backend_protocol      = "Https"
    appgw_backend_port          = 443
    appgw_backend_root_cert_pem = "-----BEGIN CERTIFICATE-----\nTU9DSw==\n-----END CERTIFICATE-----"
    # appgw_backend_host_header deliberately omitted
  }

  expect_failures = [azurerm_application_gateway.main]
}
