# Complete example: HailBytes network module → ASM HA workload.
#
# Provisions a VPC with public/private subnets using the HailBytes network
# module, then passes its outputs directly into the ha-hot-hot/aws workload
# module.  Use this as the starting point for a greenfield AWS deployment.
#
# Prerequisites:
#   1. Subscribe to HailBytes ASM on AWS Marketplace.
#   2. Issue or import an ACM certificate in the same region as var.region.
#   3. Set var.acm_certificate_arn to the certificate ARN.
#
# Usage:
#   terraform init
#   terraform apply \
#     -var='acm_certificate_arn=arn:aws:acm:us-east-1:123456789012:certificate/...' \
#     -var='allowed_cidrs=["203.0.113.0/24"]'

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# ── Variables ─────────────────────────────────────────────────────────────────

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "name_prefix" {
  type    = string
  default = "hailbytes-prod"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "az_count" {
  description = "Number of Availability Zones to span.  Minimum 2 for HA."
  type        = number
  default     = 2
}

variable "acm_certificate_arn" {
  description = "ARN of an ACM certificate in var.region, used by the ALB HTTPS listener."
  type        = string
}

variable "allowed_cidrs" {
  description = "CIDRs allowed to reach the ALB on port 443.  Restrict to your office/VPN range."
  type        = list(string)
}

# ── Network layer ─────────────────────────────────────────────────────────────

module "network" {
  source = "../../../../network/aws"

  name_prefix = var.name_prefix
  az_count    = var.az_count

  tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ── Workload layer ────────────────────────────────────────────────────────────

module "hailbytes_asm_ha" {
  source = "../.."

  product             = "asm"
  environment         = var.environment
  vpc_id              = module.network.vpc_id
  public_subnet_ids   = module.network.public_subnet_ids
  private_subnet_ids  = module.network.private_subnet_ids
  allowed_cidrs       = var.allowed_cidrs
  acm_certificate_arn = var.acm_certificate_arn
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "alb_dns_name" {
  description = "Create a DNS CNAME record pointing your domain to this address."
  value       = module.hailbytes_asm_ha.alb_dns_name
}

output "db_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the database credentials."
  value       = module.hailbytes_asm_ha.db_secret_arn
}

output "nat_gateway_public_ips" {
  description = "Allowlist these IPs on external scan targets so NAT-GW egress traffic reaches them."
  value       = module.network.nat_gateway_public_ips
}
