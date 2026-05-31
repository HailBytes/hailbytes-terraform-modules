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

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "name_prefix" {
  type    = string
  default = "hailbytes-prod"
}

variable "az_count" {
  type    = number
  default = 2
}

variable "environment" {
  type    = string
  default = "prod"
}

module "network" {
  source = "../.."

  name_prefix = var.name_prefix
  az_count    = var.az_count

  tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# Wire these outputs into a workload module:
#   module "hailbytes_asm" {
#     source             = "github.com/hailbytes/hailbytes-terraform-modules//asm-aws-ha"
#     vpc_id             = module.network.vpc_id
#     public_subnet_ids  = module.network.public_subnet_ids
#     private_subnet_ids = module.network.private_subnet_ids
#     ...
#   }

output "vpc_id" {
  description = "Pass to var.vpc_id on workload modules."
  value       = module.network.vpc_id
}

output "public_subnet_ids" {
  description = "Pass to var.public_subnet_ids on ha-hot-hot / unlimited-scale modules."
  value       = module.network.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Pass to var.private_subnet_ids (ha/autoscale) or var.subnet_id[0] (single-vm)."
  value       = module.network.private_subnet_ids
}

output "nat_gateway_public_ips" {
  description = "Allowlist these on external scan targets so NAT-GW traffic can reach them."
  value       = module.network.nat_gateway_public_ips
}
