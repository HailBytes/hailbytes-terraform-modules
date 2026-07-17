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
  default = "eu-west-1"
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

# HB-SCALE (consortium / national scale, 500k+ users): 6 x 8 = 48 metered
# vCores at steady state, bursting to 12 instances. Partner-desk SKU —
# see COST_SHAPES.md "Simplified SKUs -> module configuration".
#
# Companion app-side requirements (hailbytes-sat/docs/DATABASE_OPS.md):
# Postgres max_connections >= 220 for the 200-connection pool, and one
# SMTP sending profile per member organization.
module "hailbytes_sat_scale" {
  source = "../.."

  product             = "sat"
  environment         = var.environment
  vpc_id              = var.vpc_id
  public_subnet_ids   = var.public_subnet_ids
  private_subnet_ids  = var.private_subnet_ids
  allowed_cidrs       = var.allowed_cidrs
  acm_certificate_arn = var.acm_certificate_arn
  alert_email         = var.alert_email

  instance_type        = "m6i.2xlarge"
  asg_min_size         = 6
  asg_desired_capacity = 6
  asg_max_size         = 12

  db_instance_class           = "db.r6g.2xlarge"
  db_allocated_storage_gb     = 500
  db_max_allocated_storage_gb = 2000
  redis_node_type             = "cache.m6g.large"
}

output "alb_dns_name" { value = module.hailbytes_sat_scale.alb_dns_name }
output "autoscaling_group_name" { value = module.hailbytes_sat_scale.autoscaling_group_name }
output "db_endpoint" { value = module.hailbytes_sat_scale.db_endpoint }
output "db_read_endpoints" { value = module.hailbytes_sat_scale.db_read_endpoints }
