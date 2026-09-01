# HailBytes SAT on Azure, HA hot-hot, with a bring-your-own public IP and an
# optional Application Gateway terminating TLS on your own domain.
#
# Use this instead of ../azure-ha when any of the following is true:
#   * you run your own authoritative DNS and want the A record in place BEFORE
#     the first apply, rather than reading an address off a finished apply;
#   * you need TLS on a custom hostname with your own certificate;
#   * a host-naming standard governs the VM names.
#
# ../azure-ha cannot do any of these: it passes neither public_ip_id nor any of
# the appgw_* inputs, and the network module it uses creates no Application
# Gateway subnet.
#
# Deploying ASM instead? Change the module source to ../../modules/asm-azure-ha,
# update name_prefix, and see the appgw_backend_port note below -- ASM binds its
# admin surface on 443, not 3333.
#
#   terraform init && terraform apply

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.0, < 5.0"
    }
  }
}

provider "azurerm" {
  # Terraform's azurerm provider otherwise tries to register ~70 resource
  # providers on every apply. Registration is a SUBSCRIPTION-scoped write that
  # many least-privilege operator roles do not hold, so the apply fails closed
  # with a wall of 403s before creating anything. Register the handful this
  # stack needs once, as a subscription owner -- quickstart/preflight-azure.sh
  # checks which are missing.
  resource_provider_registrations = "none"

  features {}
}

# ----- Inputs -----

variable "resource_group_name" {
  description = "Resource group to create. All quickstart resources live here."
  type        = string
  default     = "rg-hailbytes-sat-prod"
}

variable "location" {
  description = "Azure region. northeurope = Dublin, eastus = Virginia."
  type        = string
  default     = "northeurope"
}

variable "name_prefix" {
  description = "Prefix for every resource this stack creates, except VMs when vm_names is set."
  type        = string
  default     = "hailbytes-sat"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "allowed_cidrs" {
  description = "CIDRs allowed to reach the admin console. IPv4 only -- the load balancer frontend is v4, so an IPv6 entry would pass CIDR validation and create an NSG rule that can never carry traffic. When enable_application_gateway = true the gateway's own subnet is appended automatically; see the locals block."
  type        = list(string)
}

variable "phish_allowed_cidrs" {
  description = "CIDRs allowed to reach the phishing/landing surface. Leave null and it inherits allowed_cidrs -- correct only if every simulation target sits inside your admin range. For a live simulation the targets are elsewhere, so set this (usually [\"0.0.0.0/0\"]); otherwise the campaign sends and then records no interactions."
  type        = list(string)
  default     = null
}

variable "ssh_public_key" {
  description = "SSH public key for VM admin access."
  type        = string
}

variable "admin_username" {
  type    = string
  default = "hbadmin"
}

variable "vm_names" {
  description = "Exact names for the two application VMs, in zone order -- element 0 lands in zone 1, element 1 in zone 2. Leave null to derive them from name_prefix. Renaming an existing VM REPLACES it, which on a two-node HA pair is a full outage, so treat these as a one-shot decision."
  type        = list(string)
  default     = null
}

variable "vm_size" {
  type    = string
  default = "Standard_D8s_v5"
}

variable "marketplace_image_version" {
  description = "Pin to an explicit version for a reproducible deployment. \"latest\" floats, which is wrong for anything you may need to rebuild identically."
  type        = string
  default     = "latest"
}

variable "key_vault_reader_principal_ids" {
  description = "Optional Entra object ids granted Key Vault Secrets User. The apply identity gets Secrets Officer automatically and each VM reads its own secrets via its managed identity, so the deployment needs nothing here. What an empty list costs is that when the apply runs as a service principal, only that service principal can read or rotate the database password and session keys. Grant an operator afterwards with the key_vault_id output as --scope; no re-apply needed."
  type        = list(string)
  default     = []
}

# ----- Bring your own address -----

variable "public_ip_id" {
  description = "Resource ID of an existing Static, Standard-SKU public IP for the LOAD BALANCER frontend. Leave null and the module creates one. Its lifecycle stays yours, so the address survives a terraform destroy and the DNS record stays valid across a rebuild. NOTE: when enable_application_gateway = true the gateway is the front door and this becomes an internal hop -- point DNS at appgw_public_ip_id instead."
  type        = string
  default     = null
}

variable "appgw_public_ip_id" {
  description = "Resource ID of an existing Static, Standard-SKU public IP for the APPLICATION GATEWAY frontend -- the address DNS should point at when the gateway is enabled. Leave null and the module creates one, in which case the address does not exist until the first apply completes."
  type        = string
  default     = null
}

# ----- Optional TLS on your own domain -----

variable "enable_application_gateway" {
  description = "Front the console with an Application Gateway terminating TLS. Adds roughly $187/mo (or ~$336 with a WAF policy) on top of the load balancer, which stays in the topology. Requires appgw_tls_pfx_base64, appgw_tls_pfx_password and appgw_backend_root_cert_pem."
  type        = bool
  default     = false
}

variable "appgw_tls_pfx_base64" {
  description = "Base64 of a PFX bundle for the HTTPS listener, leaf + intermediates. The PFX MUST have a password: Azure Application Gateway rejects a password-less bundle, which is easy to hit because several export paths produce one (an Azure App Service Certificate exports with an empty password). Add one with: openssl pkcs12 -in in.pfx -nodes -passin pass: -out tmp.pem && openssl pkcs12 -export -in tmp.pem -out out.pfx -passout pass:<pw>"
  type        = string
  default     = null
  sensitive   = true
}

variable "appgw_tls_pfx_password" {
  type      = string
  default   = null
  sensitive = true
}

variable "appgw_backend_root_cert_pem" {
  description = "The application VMs' TLS certificate, uploaded to the gateway as a trusted root. Required because App Gateway v2 validates the backend certificate and serves 502 if its root is not trusted. The marketplace image generates a self-signed certificate at FIRST BOOT, so it cannot exist before the VMs do -- which makes enabling the gateway a second apply. Read it off a node with: az vm run-command invoke -g <rg> -n <vm> --command-id RunShellScript --scripts 'cat /opt/hailbytes-sat/hailbytes-sat-admin.crt' --query 'value[0].message' -o tsv"
  type        = string
  default     = null
}

variable "appgw_backend_host_header" {
  description = "Host header the gateway sends to the backend, and the CN it validates the backend certificate against. The marketplace image's first-boot certificate uses CN \"hailbytes-sat-admin\", so that is the value unless you have replaced the certificate on the VMs."
  type        = string
  default     = "hailbytes-sat-admin"
}

variable "appgw_backend_port" {
  # Getting this wrong does not fail: it succeeds against the WRONG service.
  # SAT binds the admin console on 3333 over TLS, and 80 is the PHISHING server.
  # The tier module defaults to Http/80 because that suits other topologies, so
  # a gateway left on the defaults returns a healthy 200 serving landing pages
  # where the operator expects the console. ASM binds admin on 443.
  description = "Port the gateway connects to on the VMs. 3333 for SAT (admin console, TLS); 443 for ASM. NOT 80 -- on SAT that is the phishing server, and pointing the gateway at it silently fronts the landing pages instead of the console."
  type        = number
  default     = 3333
}

variable "appgw_subnet_prefix" {
  # /24 is Microsoft's recommendation, not a requirement. The real floor is
  # arithmetic: subnet size, minus the 5 addresses Azure reserves in every
  # subnet, minus the gateway's max instance count. The tier module sets
  # max_capacity = 10 with a public frontend only, so it needs 15 addresses and
  # /27 is the practical floor.
  description = "Dedicated subnet for the Application Gateway. MUST sit inside the network module's vnet_address_space (default 10.30.0.0/16) and must not overlap its lb (10.30.0.0/24), workload (10.30.10.0/24) or db (10.30.20.0/24) subnets. No other resource may share it. /24 recommended; /27 is the floor at this module's max_capacity of 10."
  type        = string
  default     = "10.30.11.0/24"
}

variable "waf_policy_id" {
  description = "Optional azurerm_web_application_firewall_policy ID. Attaching one switches the gateway from Standard_v2 to WAF_v2, which costs more."
  type        = string
  default     = null
}

# ----- Composition -----

locals {
  # The gateway reaches the VMs from its OWN subnet IPs. The AzureLoadBalancer
  # service tag does not cover those, so without adding the gateway subnet the
  # NSG drops its traffic, the backend pool never goes healthy, and the listener
  # serves 502 while every check looks correct.
  admin_cidrs = var.enable_application_gateway ? concat(var.allowed_cidrs, [var.appgw_subnet_prefix]) : var.allowed_cidrs
}

resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
}

module "network" {
  source = "../../modules/network/azure"

  name_prefix         = var.name_prefix
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  # The workload module associates its own NSGs; Azure allows one NSG per
  # subnet, so the network module must not attach its baseline set.
  associate_subnet_nsgs = false
}

# The network module creates no Application Gateway subnet, so it is created
# here, in that module's vnet.
resource "azurerm_subnet" "appgw" {
  count = var.enable_application_gateway ? 1 : 0

  name                 = "${var.name_prefix}-appgw-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = module.network.vnet_name
  address_prefixes     = [var.appgw_subnet_prefix]
}

module "hailbytes_sat" {
  source = "../../modules/sat-azure-ha"

  environment         = var.environment
  name_prefix         = var.name_prefix
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  vm_subnet_id           = module.network.workload_subnet_id
  lb_subnet_id           = module.network.lb_subnet_id
  db_delegated_subnet_id = module.network.db_delegated_subnet_id
  private_dns_zone_id    = module.network.private_dns_zone_id

  allowed_cidrs       = local.admin_cidrs
  phish_allowed_cidrs = var.phish_allowed_cidrs
  admin_username      = var.admin_username
  ssh_public_key      = var.ssh_public_key

  vm_names                  = var.vm_names
  vm_size                   = var.vm_size
  marketplace_image_version = var.marketplace_image_version

  key_vault_reader_principal_ids = var.key_vault_reader_principal_ids

  public_ip_id       = var.public_ip_id
  appgw_public_ip_id = var.appgw_public_ip_id

  enable_application_gateway = var.enable_application_gateway
  appgw_subnet_id            = var.enable_application_gateway ? azurerm_subnet.appgw[0].id : null
  appgw_tls_pfx_base64       = var.appgw_tls_pfx_base64
  appgw_tls_pfx_password     = var.appgw_tls_pfx_password
  waf_policy_id              = var.waf_policy_id

  # Https, not the module's Http default: see appgw_backend_port.
  appgw_backend_protocol      = "Https"
  appgw_backend_port          = var.appgw_backend_port
  appgw_backend_host_header   = var.appgw_backend_host_header
  appgw_backend_root_cert_pem = var.appgw_backend_root_cert_pem
}

# ----- Outputs -----

output "dns_target" {
  description = "The address your hostname must resolve to. With the gateway enabled this is the gateway frontend; without it, the load balancer frontend. These are DIFFERENT addresses, so enabling the gateway later moves DNS."
  value       = module.hailbytes_sat.load_balancer_public_ip
}

output "admin_url" {
  value = "https://${module.hailbytes_sat.load_balancer_public_ip}/"
}

output "key_vault_id" {
  description = "Scope for granting an operator Key Vault Secrets User without a re-apply: az role assignment create --role \"Key Vault Secrets User\" --assignee <upn> --scope <this>"
  value       = module.hailbytes_sat.key_vault_id
}

output "vm_ids" {
  value = module.hailbytes_sat.vm_ids
}

output "postgres_fqdn" {
  value = module.hailbytes_sat.postgres_fqdn
}
