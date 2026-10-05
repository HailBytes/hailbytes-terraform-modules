# HailBytes ASM on AWS, autoscale tier: complete quickstart.
#
# An Auto Scaling group behind an Application Load Balancer, RDS PostgreSQL,
# and the VPC around them. Every running instance meters, so asg_max_size
# caps the software bill as well as capacity.
#
# Subscribe to the HailBytes ASM listing on AWS Marketplace, run
# ../preflight-aws.sh autoscale, set allowed_cidrs in terraform.tfvars, then:
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
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0"
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
  description = "Size of each instance. m6i.large (2 vCPU) here, against the module default of m6i.2xlarge: every instance meters $0.24/vCPU-hour, and the group can grow to asg_max_size of them. Size up from measured load."
  type        = string
  default     = "m6i.large"
}

variable "acm_certificate_arn" {
  description = "ACM certificate for the console hostname. Leave null on a first deploy: this root then generates a self-signed certificate and imports it, so the console works at once and browsers warn until you supply a real one (docs/AWS_MSSP_RUNBOOK.md, Step 8)."
  type        = string
  default     = null
}

variable "deletion_protection" {
  description = "Deletion protection on the database and the load balancer. On by default, as in the module: it blocks terraform destroy by design. Set false in its own apply before a planned teardown (docs/AWS_MSSP_RUNBOOK.md, Step 10)."
  type        = bool
  default     = true
}

variable "asg_min_size" {
  description = "Instances that always run. Each meters around the clock."
  type        = number
  default     = 2
}

variable "asg_max_size" {
  description = "Ceiling the group may scale to -- and so the ceiling on the hourly software bill and the vCPU quota the region needs. The module default is 20."
  type        = number
  default     = 4
}

variable "db_read_replica_count" {
  description = "RDS read replicas. Each is a full database instance billed like the primary; the module default is 2. Start at 0 and add replicas when measured read load calls for them."
  type        = number
  default     = 0
}

locals {
  name_prefix     = var.customer == null ? "hailbytes-asm-${var.environment}" : "${var.customer}-asm-${var.environment}"
  tags            = var.customer == null ? {} : { customer = var.customer }
  certificate_arn = coalesce(var.acm_certificate_arn, one(aws_acm_certificate.self_signed[*].arn))
}

# Load-balancer and target-group names are capped at 32 characters, and the
# modules append up to six ("-phish"). Caught here it is a plan error naming the
# fix; caught by AWS it is a failure halfway through the apply.
resource "terraform_data" "name_length_guard" {
  lifecycle {
    precondition {
      condition     = length(local.name_prefix) <= 26
      error_message = "The name prefix \"${local.name_prefix}\" is ${length(local.name_prefix)} characters; load-balancer names allow 26 before the module's suffixes. Shorten customer or environment."
    }
  }
}

# A self-signed certificate, so the first deploy needs no domain and no DNS.
# Browsers warn until a real one replaces it. The private key lives in
# Terraform state, which is one more reason for the encrypted remote state in
# docs/AWS_MSSP_RUNBOOK.md, Step 4.
resource "tls_private_key" "self_signed" {
  count     = var.acm_certificate_arn == null ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "self_signed" {
  count           = var.acm_certificate_arn == null ? 1 : 0
  private_key_pem = tls_private_key.self_signed[0].private_key_pem

  subject {
    common_name  = "${local.name_prefix}.invalid"
    organization = "HailBytes quickstart (self-signed)"
  }

  validity_period_hours = 8760
  # Re-issued by any apply in the last 30 days, so it does not quietly expire.
  early_renewal_hours = 720
  allowed_uses        = ["key_encipherment", "digital_signature", "server_auth"]
}

resource "aws_acm_certificate" "self_signed" {
  count            = var.acm_certificate_arn == null ? 1 : 0
  private_key      = tls_private_key.self_signed[0].private_key_pem
  certificate_body = tls_self_signed_cert.self_signed[0].cert_pem

  lifecycle {
    create_before_destroy = true
  }
}

module "network" {
  source = "../../modules/network/aws"

  name_prefix = local.name_prefix

  # The workload module creates the VPC flow log itself, under the same IAM
  # role and log-group names, so the network module must not create a second.
  enable_flow_logs = false
}

module "hailbytes_asm" {
  source = "../../modules/asm-aws-autoscale"

  environment   = var.environment
  name_prefix   = local.name_prefix
  vpc_id        = module.network.vpc_id
  allowed_cidrs = var.allowed_cidrs
  instance_type = var.instance_type

  public_subnet_ids   = module.network.public_subnet_ids
  private_subnet_ids  = module.network.private_subnet_ids
  acm_certificate_arn = local.certificate_arn

  db_deletion_protection         = var.deletion_protection
  enable_alb_deletion_protection = var.deletion_protection

  asg_min_size          = var.asg_min_size
  asg_desired_capacity  = var.asg_min_size
  asg_max_size          = var.asg_max_size
  db_read_replica_count = var.db_read_replica_count
}

output "console_url" {
  description = "Admin console. Self-signed until you supply acm_certificate_arn, so expect a browser warning."
  value       = "https://${module.hailbytes_asm.alb_dns_name}/"
}

output "initial_credentials_command" {
  description = "Prints the first-boot admin password from each instance in turn, through SSM Run Command. This tier has no shared admin-password secret yet, so instances can differ: log in with the first one that works."
  value = join(" ", [
    "for id in $(aws autoscaling describe-auto-scaling-groups --region", var.region,
    "--auto-scaling-group-names", module.hailbytes_asm.autoscaling_group_name,
    "--query 'AutoScalingGroups[0].Instances[].InstanceId' --output text); do",
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

output "alb_access_logs_bucket" {
  description = "Load-balancer access logs. Also emptied before terraform destroy: docs/AWS_MSSP_RUNBOOK.md, Step 10."
  value       = module.hailbytes_asm.alb_access_logs_bucket
}
