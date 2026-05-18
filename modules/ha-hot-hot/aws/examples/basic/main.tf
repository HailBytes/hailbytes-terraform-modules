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
variable "vpc_id" { type = string }
variable "public_subnet_ids" { type = list(string) }
variable "private_subnet_ids" { type = list(string) }
variable "allowed_cidrs" { type = list(string) }
variable "acm_certificate_arn" { type = string }
variable "environment" {
  type    = string
  default = "prod"
}

module "hailbytes_asm_ha" {
  source = "../.."

  product             = "asm"
  environment         = var.environment
  vpc_id              = var.vpc_id
  public_subnet_ids   = var.public_subnet_ids
  private_subnet_ids  = var.private_subnet_ids
  allowed_cidrs       = var.allowed_cidrs
  acm_certificate_arn = var.acm_certificate_arn
}

output "alb_dns_name" { value = module.hailbytes_asm_ha.alb_dns_name }
output "db_secret_arn" { value = module.hailbytes_asm_ha.db_secret_arn }
output "alb_arn" { value = module.hailbytes_asm_ha.alb_arn }
output "instance_ids" { value = module.hailbytes_asm_ha.instance_ids }
