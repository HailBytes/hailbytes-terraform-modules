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
variable "alert_email" {
  type    = string
  default = null
}
variable "environment" {
  type    = string
  default = "prod"
}

module "hailbytes_asm_scale" {
  source = "../.."

  product             = "asm"
  environment         = var.environment
  vpc_id              = var.vpc_id
  public_subnet_ids   = var.public_subnet_ids
  private_subnet_ids  = var.private_subnet_ids
  allowed_cidrs       = var.allowed_cidrs
  acm_certificate_arn = var.acm_certificate_arn
  alert_email         = var.alert_email
}

output "alb_dns_name" { value = module.hailbytes_asm_scale.alb_dns_name }
output "autoscaling_group_name" { value = module.hailbytes_asm_scale.autoscaling_group_name }
output "db_endpoint" { value = module.hailbytes_asm_scale.db_endpoint }
output "db_read_endpoints" { value = module.hailbytes_asm_scale.db_read_endpoints }
