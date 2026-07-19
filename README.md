# HailBytes Terraform Modules

> Official Terraform modules for deploying **HailBytes ASM** (Attack Surface Management) and **HailBytes SAT** (Security Awareness Training) on AWS and Azure.

[![License: MPL 2.0](https://img.shields.io/badge/License-MPL_2.0-brightgreen.svg)](https://opensource.org/licenses/MPL-2.0)
[![Terraform](https://img.shields.io/badge/Terraform-%3E%3D1.5-623CE4.svg)](https://www.terraform.io)
[![AWS](https://img.shields.io/badge/AWS-Supported-FF9900.svg)](https://aws.amazon.com)
[![Azure](https://img.shields.io/badge/Azure-Supported-0078D4.svg)](https://azure.microsoft.com)

> ⚠️ **Requires an active HailBytes Marketplace subscription.** The Terraform is free and open source; the VM images it deploys are commercial software billed through AWS Marketplace or Azure Marketplace. Accept the offer for your product *before* `terraform apply`, or AMI/image lookup will fail. [Get started at hailbytes.com/deploy](https://hailbytes.com/deploy).

---

## 🚀 Quickstart

New here? [`quickstart/azure-ha`](quickstart/azure-ha) takes you from an empty subscription to a running HA deployment in one `terraform apply` (or one pasted Azure Cloud Shell command). It creates the networking prerequisites for you, so there is nothing to figure out before your first apply. Each workload module also ships an `examples/basic` config for teams composing into an existing landing zone.

## Overview

These modules implement the HailBytes BYOC (Bring Your Own Cloud) deployment model. Your HailBytes instance runs in your own AWS or Azure account — your data never leaves your infrastructure.

## Marketplace subscriptions

| Product | Overview | AWS Marketplace | Azure Marketplace | Demo |
|---|---|---|---|---|
| **HailBytes ASM** — Attack Surface Management | [hailbytes.com/asm](https://hailbytes.com/asm/) | [Subscribe](https://aws.amazon.com/marketplace/pp/prodview-66d5bswmbtfhs) | [Subscribe](https://marketplace.microsoft.com/en-us/product/virtual-machines/lcmcon1687976613543.hardened_ubuntu_with_rengine) | [Watch](https://youtu.be/suYUuOP7JUk) |
| **HailBytes SAT** — Security Awareness Training (phishing simulation, training campaigns) | [hailbytes.com/sat](https://hailbytes.com/sat/) | [Subscribe](https://aws.amazon.com/marketplace/pp/prodview-yyk6iton3ghu4) | [Subscribe](https://marketplace.microsoft.com/en-us/product/virtual-machines/lcmcon1687976613543.gophish-phishing-simulator?tab=overview) | [Watch](https://youtu.be/kfNEhpFHPLA) |

---

## Available modules

Pick the module that matches your **product** × **cloud** × **tier**. Each module has one job and sensible defaults; you don't set a `product` variable.

### HailBytes ASM

| Module | Cloud | Tier | Use case |
|---|---|---|---|
| [`modules/asm-aws-single`](modules/asm-aws-single) | AWS | Single VM | Dev, PoC, SMB, single operator |
| [`modules/asm-aws-ha`](modules/asm-aws-ha) | AWS | HA hot-hot | Production SOC, Multi-AZ durability |
| [`modules/asm-aws-autoscale`](modules/asm-aws-autoscale) | AWS | Auto-scaling | MSSP, large enterprise, elastic scan workloads |
| [`modules/asm-azure-single`](modules/asm-azure-single) | Azure | Single VM | Dev, PoC, SMB |
| [`modules/asm-azure-ha`](modules/asm-azure-ha) | Azure | HA hot-hot | Production SOC, Zone-Redundant |
| [`modules/asm-azure-autoscale`](modules/asm-azure-autoscale) | Azure | Auto-scaling | MSSP, large enterprise |

### HailBytes SAT

| Module | Cloud | Tier | Use case |
|---|---|---|---|
| [`modules/sat-aws-single`](modules/sat-aws-single) | AWS | Single VM | Dev, PoC, small/mid-market |
| [`modules/sat-aws-ha`](modules/sat-aws-ha) | AWS | HA hot-hot | Production, multi-AZ |
| [`modules/sat-aws-autoscale`](modules/sat-aws-autoscale) | AWS | Auto-scaling | Large-population training (100k+ users), bursty campaigns, report generation |
| [`modules/sat-azure-single`](modules/sat-azure-single) | Azure | Single VM | Dev, PoC, small/mid-market |
| [`modules/sat-azure-ha`](modules/sat-azure-ha) | Azure | HA hot-hot | Production, Zone-Redundant |
| [`modules/sat-azure-autoscale`](modules/sat-azure-autoscale) | Azure | Auto-scaling | Large-population training, bursty campaigns |

### Supporting modules

| Module | Description |
|---|---|
| [`modules/network/aws`](modules/network/aws) | Optional VPC + 3-tier subnets + NAT gateways + Flow Logs. Use if you don't already have a landing zone. |
| [`modules/network/azure`](modules/network/azure) | Optional vnet + workload/LB/delegated-Postgres subnets + private DNS zone. |

---

## Which tier do I need?

```
                       Start here
                            │
             ┌── Will you run this in production? ──┐
             │                                       │
            No                                       Yes
             │                                       │
          *-single                ┌── Bursty workloads, MSSP, large-population
          (dev / PoC /            │   training, or high-volume scans?
          single operator)        │
                                 Yes                       No
                                  │                         │
                            *-autoscale                  *-ha
                            (ASG / VMSS,                 (2× active/active
                            read replicas,               behind LB, Multi-AZ
                            CloudWatch / Azure           managed Postgres)
                            Monitor)
```

| Tier | Approx. AWS infra cost (us-east-1, default sizing) |
|---|---|
| `*-single` | **~$70/mo** — 1× `t3.large`, EBS gp3 |
| `*-ha` | **~$420/mo** — 2× `t3.large` + ALB + `db.t3.medium` Multi-AZ RDS |
| `*-autoscale` | **~$1,200+/mo** — ASG min 3, `db.r6g.large` Multi-AZ + read replica, ALB, CloudWatch |

> Infra costs **exclude HailBytes marketplace software fees**, which are billed separately by AWS/Azure on top of the VM hours. See per-module READMEs for sizing and Azure equivalents.

---

## Quick start

> No `v1.0.0` tag has been cut on this repo yet (see [#48](https://github.com/HailBytes/hailbytes-terraform-modules/issues/48)). The `?ref=v1.0.0` pins below will fail `terraform init` with a "reference not found" error until a tag exists — pin to a commit SHA instead (e.g. `?ref=d0de3d5`) and update the pin once a tagged release ships.

### ASM on AWS (single VM)

```hcl
module "hailbytes_asm" {
  source = "github.com/hailbytes/hailbytes-terraform-modules//modules/asm-aws-single?ref=v1.0.0"

  environment   = "prod"
  vpc_id        = "vpc-xxxxxxxx"
  subnet_id     = "subnet-xxxxxxxx"
  allowed_cidrs = ["10.0.0.0/8"]
}
```

### SAT on Azure (auto-scaling, large-population training)

```hcl
module "hailbytes_sat" {
  source = "github.com/hailbytes/hailbytes-terraform-modules//modules/sat-azure-autoscale?ref=v1.0.0"

  environment            = "prod"
  resource_group_name    = "rg-hailbytes-prod"
  location               = "eastus"
  vm_subnet_id           = azurerm_subnet.workload.id
  db_delegated_subnet_id = azurerm_subnet.db.id
  private_dns_zone_id    = azurerm_private_dns_zone.pg.id
  allowed_cidrs          = ["10.0.0.0/8"]
  admin_username         = "hbadmin"
  ssh_public_key         = file("~/.ssh/id_ed25519.pub")
  alert_email            = "soc-oncall@example.com"

  vmss_min_count   = 3
  vmss_max_count   = 30
  db_replica_count = 2
}
```

See each module's `examples/` directory for runnable configurations.

---

## How the modules are structured

Each product-prefixed module (e.g. `asm-aws-ha`) is a thin wrapper around an internal tier module (`modules/single-vm/aws`, `modules/ha-hot-hot/aws`, `modules/unlimited-scale/aws` and their Azure counterparts) with `product` hardcoded. The wrappers are the **public interface** — what you import. The tier modules underneath are the **implementation** — one source of truth for each tier × cloud combination.

This means a security fix or feature change to the HA tier on AWS lands in `modules/ha-hot-hot/aws/` once and is automatically picked up by both `asm-aws-ha` and `sat-aws-ha`.

You can import the tier modules directly if you want to set `product` yourself, but the product-prefixed names are the supported public API.

---

## Billing cohesion — why we ship Terraform but not the software

HailBytes ships **infrastructure-as-code (free, MPL-2.0)** that orchestrates **commercial VM images (paid, billed by the cloud marketplace)**. The Terraform is the deployment recipe; the AMI/VHD is the product.

Every module deploys *exclusively* from a published HailBytes Marketplace image. There are no Dockerfiles, no source bundles, no raw installers, no `user_data` that downloads a payload from S3. This keeps customer payment, license entitlement, and HailBytes revenue all flowing through one cloud-native billing rail.

See [BILLING.md](BILLING.md) for the full model.

---

## Support matrix

| Module | Terraform | AWS provider | Azure provider | Tested clouds |
|---|---|---|---|---|
| All | `>= 1.5.0` | `>= 5.0` | `>= 4.0, < 5.0` | AWS commercial regions, Azure commercial regions |

GovCloud (AWS) and Azure Government are out of scope for v1.

---

## Patching and migration safety

Every module ships a procurement-grade safety net for HailBytes patches
and schema migrations: customer-initiated pre-patch backups (immutable
S3 / Azure Storage), rolling-replace with auto-rollback, post-patch
schema-version verification, and a DB-on-VM toggle for compliance-led
deployments. None of this requires manual portal clicks after
`terraform apply`.

See **[docs/PATCHING_AND_MIGRATION.md](docs/PATCHING_AND_MIGRATION.md)**
for the customer-facing runbook, the audit pointers for procurement /
security reviewers, and the variable reference.

The companion HailBytes SAT change (export / import API endpoints, plus
on-VM `ha-pre-patch-backup.sh` / `ha-post-patch-verify.sh` scripts) lands
in
[`hailbytes-sat@c804cac`](https://github.com/HailBytes/hailbytes-sat)
with the runbook in
[`hailbytes-sat/docs/AWS_HA_DEPLOYMENT.md`](https://github.com/HailBytes/hailbytes-sat/blob/main/docs/AWS_HA_DEPLOYMENT.md).

---

## Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md) — per-tier diagrams and rationale, shared responsibility model
- [BILLING.md](BILLING.md) — marketplace billing model, why no containers
- [COST_SHAPES.md](COST_SHAPES.md) — three AWS deployment shapes side-by-side (single / HA / unlimited-scale) with per-vCore meter and procurement-grade pricing
- [SECURITY.md](SECURITY.md) — responsible disclosure
- [SECURITY-DEFAULTS.md](SECURITY-DEFAULTS.md) — encryption / IMDSv2 / IAM / NSG defaults baked into modules
- [docs/PATCHING_AND_MIGRATION.md](docs/PATCHING_AND_MIGRATION.md) — pre-patch backups, rolling-replace, auto-rollback, DB mode toggle
- [CHANGELOG.md](CHANGELOG.md) — release history

---

## Support

- 📧 [support@hailbytes.com](mailto:support@hailbytes.com)
- 📖 [hailbytes.com/deploy](https://hailbytes.com/deploy)
- 🔒 Security issues: see [SECURITY.md](SECURITY.md)

---

## Contributing

PRs welcome. Every PR must pass `terraform validate`, `tflint`, `checkov`, and `trivy` (see [`.github/workflows`](.github/workflows)).

**Contributions that bypass marketplace billing will be closed without merge.** This includes:

- Dockerfiles or container manifests for HailBytes products
- `user_data` / cloud-init that downloads HailBytes binaries from a non-marketplace source
- Modules that deploy from custom-built AMIs/VHDs rather than the Marketplace listing
- Any path that lets a customer run HailBytes software without a marketplace subscription

---

## License

Mozilla Public License 2.0 — see [LICENSE](LICENSE) for details.
HailBytes software itself is commercial and requires an active marketplace subscription.
