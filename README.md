# HailBytes Terraform Modules

> Official Terraform modules for deploying **HailBytes ASM** (Attack Surface Management) and **HailBytes SAT** (Security Awareness Training) on AWS and Azure.

[![License: MPL 2.0](https://img.shields.io/badge/License-MPL_2.0-brightgreen.svg)](https://opensource.org/licenses/MPL-2.0)
[![Terraform](https://img.shields.io/badge/Terraform-%3E%3D1.5-623CE4.svg)](https://www.terraform.io)
[![AWS](https://img.shields.io/badge/AWS-Supported-FF9900.svg)](https://aws.amazon.com)
[![Azure](https://img.shields.io/badge/Azure-Supported-0078D4.svg)](https://azure.microsoft.com)

> ⚠️ **Requires an active HailBytes Marketplace subscription.** [Get started at hailbytes.com/deploy](https://hailbytes.com/deploy)

---

## Overview

These modules implement the HailBytes BYOC (Bring Your Own Cloud) deployment model. Your HailBytes instance runs in your own AWS or Azure account — your data never leaves your infrastructure.

### Available Modules

| Module | Cloud | Description |
|--------|-------|-------------|
| `modules/asm-aws-single` | AWS | ASM single-VM (dev/eval) |
| `modules/asm-aws-ha` | AWS | ASM HA hot-hot (multi-AZ) |
| `modules/asm-aws-autoscale` | AWS | ASM auto-scaling tier |
| `modules/asm-azure-single` | Azure | ASM single-VM (dev/eval) |
| `modules/asm-azure-ha` | Azure | ASM HA hot-hot (multi-region) |
| `modules/sat-aws-single` | AWS | SAT single-VM (dev/eval) |
| `modules/sat-aws-ha` | AWS | SAT HA hot-hot (multi-AZ) |
| `modules/sat-azure-single` | Azure | SAT single-VM (dev/eval) |

---

## Prerequisites

- Terraform >= 1.5
- Active HailBytes Marketplace subscription (AWS Marketplace or Azure Marketplace)
- Your HailBytes license key (provisioned at subscription time)
- AWS CLI or Azure CLI configured with appropriate permissions

---

## Quick Start — ASM on AWS (Single VM)

```hcl
module "hailbytes_asm" {
  source  = "HailBytes/asm-aws-single/hailbytes"
  version = "~> 1.0"

  license_key        = var.hailbytes_license_key
  vpc_id             = "vpc-xxxxxxxx"
  subnet_id          = "subnet-xxxxxxxx"
  instance_type      = "t3.large"
  allowed_cidr_blocks = ["10.0.0.0/8"]
}
```

---

## Quick Start — ASM on Azure (HA)

```hcl
module "hailbytes_asm_ha" {
  source  = "HailBytes/asm-azure-ha/hailbytes"
  version = "~> 1.0"

  license_key         = var.hailbytes_license_key
  resource_group_name = "rg-hailbytes-prod"
  location            = "eastus"
  vm_size             = "Standard_D4s_v3"
}
```

---

## Deployment Tiers

| Tier | Use Case | Availability | Min Spec |
|------|----------|-------------|----------|
| Single VM | Dev, eval, small orgs | No HA | 4 vCPU / 16 GB |
| HA hot-hot | Production, enterprise | Multi-AZ/region | 8 vCPU / 32 GB (×2) |
| Auto-scaling | MSSP, large enterprise | Multi-AZ + ASG | 4 vCPU / 16 GB (min 2) |

---

## MSSP Deployments

MSSPs can use the auto-scaling tier with tenant namespacing to run a single HailBytes cluster serving multiple customer environments. See [`docs/mssp-deployment.md`](docs/mssp-deployment.md).

---

## Support

- 📧 [support@hailbytes.com](mailto:support@hailbytes.com)
- 📖 [hailbytes.com/deploy](https://hailbytes.com/deploy)
- 🔒 Security issues: see [SECURITY.md](SECURITY.md)

---

## License

Mozilla Public License 2.0 — see [LICENSE](LICENSE) for details.  
HailBytes software itself is commercial and requires a valid license key.
