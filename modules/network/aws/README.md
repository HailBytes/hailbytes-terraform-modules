# `network/aws`

Opinionated VPC scaffolding for HailBytes workload modules. Three-tier subnet layout (public, private, db) across 2 or 3 AZs, NAT gateway per AZ for HA egress, VPC Flow Logs to CloudWatch.

**You do not need this module if you already have a landing zone.** The workload modules (`single-vm`, `ha-hot-hot`, `unlimited-scale`) accept `vpc_id` and subnet IDs directly. This module is for customers without their own network.

## Architecture

```
              ┌─ Internet Gateway
              │
   Public-a  Public-b  (Public-c)       ← ALB lives here
      │         │           │
   NAT-a    NAT-b      (NAT-c)          ← one per AZ, for egress
      │         │           │
   Private-a Private-b (Private-c)      ← VMs / ASG / VMSS live here
                                          (egress through NAT)
   DB-a       DB-b      (DB-c)           ← RDS / Postgres lives here
                                          (no internet route)
```

## Usage

```hcl
module "network" {
  source = "github.com/hailbytes/hailbytes-terraform-modules//modules/network/aws?ref=v1.0.0"

  name_prefix = "hailbytes-asm-prod"
  vpc_cidr    = "10.20.0.0/16"
  az_count    = 3
}

module "hailbytes_asm_scale" {
  source = "github.com/hailbytes/hailbytes-terraform-modules//modules/unlimited-scale/aws?ref=v1.0.0"

  product             = "asm"
  vpc_id              = module.network.vpc_id
  public_subnet_ids   = module.network.public_subnet_ids
  private_subnet_ids  = module.network.private_subnet_ids
  allowed_cidrs       = ["10.0.0.0/8"]
  acm_certificate_arn = aws_acm_certificate.main.arn
}
```

## Notable outputs

- `nat_gateway_public_ips` — allowlist these on external scan targets you control so HailBytes ASM can reach them through your NAT. (Salvaged pattern from the deprecated `byoc-security-architecture-templates` repo.)

## Inputs

See [`variables.tf`](variables.tf). Required: `name_prefix`. All others have defaults.

## Outputs

See [`outputs.tf`](outputs.tf).
