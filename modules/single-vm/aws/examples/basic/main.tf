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
variable "subnet_id" { type = string }
variable "allowed_cidrs" { type = list(string) }
variable "environment" {
  type    = string
  default = "dev"
}

module "hailbytes_asm" {
  source = "../.."

  product       = "asm"
  environment   = var.environment
  vpc_id        = var.vpc_id
  subnet_id     = var.subnet_id
  allowed_cidrs = var.allowed_cidrs
}

output "instance_id" {
  value = module.hailbytes_asm.instance_id
}

output "private_ip" {
  value = module.hailbytes_asm.private_ip
}

output "console_url" {
  value = module.hailbytes_asm.console_url
}
