# HailBytes ASM on AWS, single-VM tier: complete quickstart.
#
# One EC2 instance with a public IP and the database on board, in a VPC this
# root builds. No load balancer and no redundancy: a reboot is an outage.
#
# Subscribe to the HailBytes ASM listing on AWS Marketplace, run
# ../preflight-aws.sh single, set allowed_cidrs in terraform.tfvars, then:
#
#   terraform init && terraform apply
#
# Per-client (MSSP) deployments: docs/AWS_MSSP_RUNBOOK.md.
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0, < 6.0"
    }
  }
}

provider "aws" {
  region = var.region

  # One place for the customer tag, so it reaches every resource -- including
  # the ones the modules create -- without threading it through each of them.
  default_tags {
    tags = local.tags
  }
}

variable "region" {
  description = "AWS region. us-east-1 = N. Virginia, eu-west-1 = Ireland, sa-east-1 = Sao Paulo."
  type        = string
  default     = "us-east-1"
}

variable "customer" {
  description = "Short client name when you run one deployment per client (MSSP). Prefixes every resource and tags everything customer=<name> for per-client cost reports. Leave null for a single-organisation deployment. Set it on the FIRST apply only: changing it later renames, and so replaces, every resource."
  type        = string
  default     = null

  validation {
    condition     = var.customer == null || can(regex("^[a-z][a-z0-9-]{1,15}$", var.customer))
    error_message = "customer must be 2-16 characters: lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "allowed_cidrs" {
  description = "CIDRs allowed to reach the admin console (e.g. your office egress IP as x.x.x.x/32)."
  type        = list(string)
}

variable "instance_type" {
  description = "Size of each application instance. Matches the module default (8 vCPU). Every vCPU meters $0.24/hour, so size this from measured load; check quota with ../preflight-aws.sh."
  type        = string
  default     = "m6i.2xlarge"
}

locals {
  name_prefix = var.customer == null ? "hailbytes-asm-${var.environment}" : "${var.customer}-asm-${var.environment}"
  tags        = var.customer == null ? {} : { customer = var.customer }
}

module "network" {
  source = "../../modules/network/aws"

  name_prefix = local.name_prefix

  # The workload module creates the VPC flow log itself, under the same IAM
  # role and log-group names, so the network module must not create a second.
  enable_flow_logs = false

  # The single VM sits in a public subnet with its own address, so it needs no
  # NAT gateway -- which saves its hourly cost and two of the region's five
  # default Elastic IPs.
  enable_nat_gateway = false
}

module "hailbytes_asm" {
  source = "../../modules/asm-aws-single"

  environment   = var.environment
  name_prefix   = local.name_prefix
  vpc_id        = module.network.vpc_id
  allowed_cidrs = var.allowed_cidrs
  instance_type = var.instance_type

  subnet_id           = module.network.public_subnet_ids[0]
  associate_public_ip = true
}

output "console_url" {
  description = "Admin console. The certificate is self-signed on first boot, so expect a browser warning."
  value       = "https://${module.hailbytes_asm.public_ip}/"
}

output "public_ip" {
  value = module.hailbytes_asm.public_ip
}

output "initial_credentials_command" {
  description = "Prints the first-boot admin password, read from the instance through SSM Run Command."
  value = join(" ", [
    "for id in", module.hailbytes_asm.instance_id, "; do",
    "cid=$(aws ssm send-command --region", var.region, "--instance-ids \"$id\" --document-name AWS-RunShellScript",
    "--parameters 'commands=[\"sudo grep DJANGO_SUPERUSER_PASSWORD /opt/hailbytes-asm/.env\"]' --query Command.CommandId --output text)",
    "&& sleep 5 && aws ssm get-command-invocation --region", var.region,
    "--command-id \"$cid\" --instance-id \"$id\" --query StandardOutputContent --output text; done",
  ])
}

output "backup_bucket_name" {
  description = "Object-locked backup bucket. It must be emptied before terraform destroy can remove it: docs/AWS_MSSP_RUNBOOK.md, Step 10."
  value       = module.hailbytes_asm.backup_bucket_name
}
