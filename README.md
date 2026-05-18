# HailBytes Terraform Modules

Production-grade Terraform modules for deploying HailBytes products (ASM, SAT) from official **AWS Marketplace** and **Azure Marketplace** VM images.

> [!IMPORTANT]
> **These modules require an active HailBytes Marketplace subscription. The modules themselves are free and open source; the VM images they deploy are commercial software billed through AWS Marketplace or Azure Marketplace.**
>
> You must accept the marketplace offer for your chosen product *before* `terraform apply`, or AMI/image lookup will fail.

---

## Marketplace subscription links

| Product | Overview | AWS Marketplace | Azure Marketplace | Demo |
|---|---|---|---|---|
| **HailBytes ASM** — Attack Surface Management | [hailbytes.com/asm](https://hailbytes.com/asm/) | [Subscribe on AWS](https://aws.amazon.com/marketplace/pp/prodview-66d5bswmbtfhs) | [Subscribe on Azure](https://marketplace.microsoft.com/en-us/product/virtual-machines/lcmcon1687976613543.hardened_ubuntu_with_rengine) | [Watch](https://youtu.be/suYUuOP7JUk) |
| **HailBytes SAT** — Security Awareness Training (phishing simulation) | [hailbytes.com/sat](https://hailbytes.com/sat/) | [Subscribe on AWS](https://aws.amazon.com/marketplace/pp/prodview-yyk6iton3ghu4) | [Subscribe on Azure](https://marketplace.microsoft.com/en-us/product/virtual-machines/lcmcon1687976613543.gophish-phishing-simulator?tab=overview) | [Watch](https://youtu.be/kfNEhpFHPLA) |

---

## Which tier do I need?

```
                       Start here
                            │
             ┌── Will you run this in production? ──┐
             │                                       │
            No                                       Yes
             │                                       │
        single-vm                  ┌── Do you need elastic scale or
        (dev / PoC /               │   multi-tenant (MSSP) capacity?
         SMB / single              │
         operator)                Yes                  No
                                   │                   │
                          unlimited-scale         ha-hot-hot
                          (ASG / VMSS,            (2× active/active
                           read replicas,         behind LB, Multi-AZ
                           CloudWatch/            managed Postgres)
                           Azure Monitor)
```

| Tier | Use case | Approx. infra cost (us-east-1, default sizing) |
|---|---|---|
| [`single-vm`](modules/single-vm) | Dev, PoC, SMB, single operator | **~$70/mo** — 1× `t3.large`, EBS gp3 |
| [`ha-hot-hot`](modules/ha-hot-hot) | Production SOC, durability SLA | **~$420/mo** — 2× `t3.large` + ALB + `db.t3.medium` Multi-AZ RDS |
| [`unlimited-scale`](modules/unlimited-scale) | MSSP, large enterprise, elastic workloads | **~$1,200+/mo** — ASG min 3, `db.r6g.large` Multi-AZ + read replica, ALB, CloudWatch |

> Infra costs **exclude HailBytes marketplace software fees**, which are billed separately by AWS/Azure on top of the VM hours. See per-module READMEs for sizing details and Azure equivalents.

---

## Modules

```
modules/
  single-vm/
    aws/        # 1× EC2 from HailBytes Marketplace AMI
    azure/      # 1× Azure VM from HailBytes Marketplace image
  ha-hot-hot/
    aws/        # 2× EC2 active/active, ALB, RDS PostgreSQL Multi-AZ
    azure/      # 2× VM active/active, Azure LB, Azure Database for PostgreSQL
  unlimited-scale/
    aws/        # Auto Scaling Group, ALB, RDS + read replicas, CloudWatch
    azure/      # VM Scale Set, Azure LB, Azure DB for PostgreSQL + read replicas, Azure Monitor
  network/      # OPTIONAL bundled networking for customers without a landing zone
    aws/        # VPC + 3-tier subnets across N AZs + NAT + Flow Logs
    azure/      # Vnet + workload/LB/delegated DB subnets + private DNS zone
```

The workload modules accept your existing VPC / vnet by ID. Use `network/*` only if you don't already have a landing zone.

---

## Quick start

```hcl
module "hailbytes_asm" {
  source = "github.com/hailbytes/hailbytes-terraform-modules//modules/single-vm/aws?ref=v1.0.0"

  product       = "asm"
  environment   = "prod"
  instance_type = "t3.large"
  vpc_id        = "vpc-xxxxxxxx"
  subnet_id     = "subnet-xxxxxxxx"
  allowed_cidrs = ["10.0.0.0/8"]
  key_name      = "my-keypair"
}
```

See each module's `examples/` directory for runnable configurations.

---

## Billing cohesion — why we ship Terraform but not the software

HailBytes ships **infrastructure-as-code (free, Apache-2.0)** that orchestrates **commercial VM images (paid, billed by the cloud marketplace)**. The Terraform is the deployment recipe; the AMI/VHD is the product.

Every module in this repo deploys *exclusively* from a published HailBytes Marketplace image. There are no Dockerfiles, no source bundles, no raw installers, no `user_data` that downloads a payload from S3. This keeps customer payment, license entitlement, and HailBytes revenue all flowing through one cloud-native billing rail.

See [BILLING.md](BILLING.md) for the full model.

---

## Support matrix

| Module | Terraform | AWS provider | Azure provider | Tested clouds |
|---|---|---|---|---|
| All | `>= 1.5.0` | `>= 5.0` | `>= 3.0` | AWS commercial regions, Azure commercial regions |

GovCloud (AWS) and Azure Government are out of scope for v1.

---

## Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md) — per-tier diagrams and rationale, shared responsibility model
- [BILLING.md](BILLING.md) — marketplace billing model, why no containers
- [SECURITY.md](SECURITY.md) — security defaults baked into modules
- [CHANGELOG.md](CHANGELOG.md) — release history

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

[Apache-2.0](LICENSE). Why Apache-2.0 instead of MPL-2.0: HailBytes revenue comes from marketplace VM image billing, *not* from the IaC. Permissive licensing maximizes adoption — partners, MSSPs, and customers can embed these modules in their own platforms without copyleft friction. The marketplace billing rail is the moat; the Terraform is sales enablement.

---

## Links

- Website: [hailbytes.com](https://hailbytes.com)
- GitHub: [github.com/HailBytes](https://github.com/HailBytes)
- YouTube: [youtube.com/c/HailBytes](https://www.youtube.com/c/HailBytes)
- ASM demo: <https://youtu.be/suYUuOP7JUk>
- SAT demo: <https://youtu.be/kfNEhpFHPLA>
