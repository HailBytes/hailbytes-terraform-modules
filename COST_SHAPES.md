# Cost Shapes — HailBytes Terraform Modules

> Fast reference for the three AWS deployment shapes. Updated alongside
> the canonical procurement-grade table in
> [`hailbytes-sat/docs/AWS_HA_DEPLOYMENT.md` § Estimated monthly cost](https://github.com/HailBytes/hailbytes-sat/blob/main/docs/AWS_HA_DEPLOYMENT.md#estimated-monthly-cost-ha-vs-single-instance).
> If you're updating prices for procurement, edit the runbook first, then
> mirror the change here. Each module README quotes its own row and
> links back to this file for the cross-tier comparison.

## The three shapes (us-east-1, on-demand, list price, rounded)

A "shape" is the topology — single instance, HA two-node, or
horizontally-scaling ASG. Each has fundamentally different cost
behaviour, so they're not interpolatable: don't quote "2× a single
instance" for HA, or "5× HA" for unlimited-scale.

| Shape | Module | Instances | Managed services | Infra | + per-vCore meter | **All-in (procurement-grade)** |
|---|---|---|---|---|---|---|
| **Single** | [`single-vm/aws`](modules/single-vm/aws) | 1× `m6i.large` | none | ~$84/mo | 2 vCPU × 730h × $0.24 = ~$350/mo | **~$435/mo** |
| **HA hot-hot** | [`ha-hot-hot/aws`](modules/ha-hot-hot/aws) | 2× `m6i.large` | ALB + ElastiCache Multi-AZ + RDS Multi-AZ `db.m6g.large` | ~$515/mo | 4 vCPU × 730h × $0.24 = ~$700/mo | **~$1,215/mo (≈ 2.8× single)** |
| **HA hot-hot, self-managed DB** | [`ha-hot-hot/aws`](modules/ha-hot-hot/aws) with `db_mode = "ec2"` | 2× `m6i.large` app + 1× `m6i.large` DB | ALB + ElastiCache Multi-AZ | ~$345/mo | 6 vCPU × 730h × $0.24 = ~$1,050/mo | **~$1,395/mo (≈ 3.2× single)** |
| **Unlimited scale** | [`unlimited-scale/aws`](modules/unlimited-scale/aws) | 3× `m6i.large` (ASG min) | ALB + ElastiCache + RDS primary + 2 read replicas (`db.r6g.large`) | ~$1,200/mo | 6 vCPU × 730h × $0.24 = ~$1,050/mo | **~$2,250/mo at min, ~$4,700/mo at 10 instances** |

## Per-vCore meter (the big one)

The HailBytes per-vCore Marketplace meter — `$0.24/vCPU-hour` — is
typically the largest single line in HA and unlimited-scale deployments.
It scales with **instance count**, not topology, so doubling app
instances doubles the meter regardless of how much shared infra they
sit behind. Treat it as a first-class cost in every quote.

| Instance type | vCPU | Per-month per instance (24/7) |
|---|---|---|
| `t3.large` | 2 | $350 |
| `m6i.large` | 2 | $350 |
| `m6i.xlarge` | 4 | $700 |
| `m6i.2xlarge` | 8 | $1,400 |

For deployments running Savings Plans or Enterprise Discount Program
(EDP) discounts on the meter, the account team can quote a custom
number — these list prices are the procurement starting point.

## Starter defaults vs procurement-grade sizing

Each module ships with **starter defaults** (smaller, cheaper) so a
fresh `terraform apply` produces a reasonable PoC without burning
$1k/mo of budget. The procurement-grade numbers above use the larger
sizing the account team and the SAT runbook quote. The variables to
move from Starter → Procurement-grade in `ha-hot-hot/aws`:

```hcl
module "hailbytes_sat_ha" {
  source = "github.com/hailbytes/hailbytes-terraform-modules//modules/ha-hot-hot/aws?ref=v1.0.0"

  # Procurement-grade overrides (defaults are the Starter shape)
  instance_type     = "m6i.large"      # default: t3.large
  db_instance_class = "db.m6g.large"   # default: db.t3.medium
  # redis_node_type already defaults to cache.t4g.small — fine for both shapes
  # ...
}
```

Each module README shows its own Starter vs Procurement-grade table.

## EU / data-residency pricing note

Asiera / HEAnet and other EU/EEA-resident deployments: prices in
`eu-west-1` (Dublin, recommended default) and `eu-central-1`
(Frankfurt, fallback) are within roughly ±5% of `us-east-1`. The
procurement-grade column above holds in either region. All managed
services in the topology keep data in-region; the per-vCore meter
does not require any data to leave the customer VPC.

## When prices change

1. Update the canonical table in `hailbytes-sat/docs/AWS_HA_DEPLOYMENT.md § Estimated monthly cost`.
2. Mirror the change in this file (the rows above and the meter table).
3. Spot-check the per-module READMEs (`modules/single-vm/aws/README.md`,
   `modules/ha-hot-hot/aws/README.md`, `modules/unlimited-scale/aws/README.md`)
   — only edit them if the **Starter default** sizing changed; the
   procurement-grade column should already link here.

Azure pricing is currently tracked separately in each Azure module's
README. We'll fold it into this file once the SAT runbook adds an
Azure cost table.
