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

> **This table shows procurement-grade sizing (`m6i.large`), not the
> module defaults.** A fresh `terraform apply` uses the cheaper starter
> defaults (`t3.large`) — see
> [Starter defaults vs procurement-grade sizing](#starter-defaults-vs-procurement-grade-sizing)
> before quoting these numbers.

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

## Simplified SKUs → module configuration

The channel price list quotes fixed annual plans (the "simplified SKUs").
Each SKU's vCore count is the **total metered vCPU at steady state** —
it maps onto a specific module + sizing overrides. Module defaults stay
at the Starter shape; a SKU is fulfilled by applying the overrides below
(runnable examples live in each module's `examples/` directory where
noted).

| SKU | Plan | Metered vCores | Module | Overrides vs defaults |
|---|---|---|---|---|
| `HB-ESS` | Essential | 8 | `single-vm/aws` | `instance_type = "m6i.2xlarge"` |
| `HB-STD` | Standard | 12 | `unlimited-scale/aws` | `instance_type = "m6i.xlarge"`, `asg_min_size = asg_desired_capacity = 3`, `asg_max_size = 3` (raise only if the customer enables auto-scaling) |
| `HB-PRO` | Professional | 16 | `single-vm/aws` | `instance_type = "m6i.4xlarge"` |
| `HB-PRO-HA` | Professional HA | 16 (2 × 8) | `ha-hot-hot/aws` | `instance_type = "m6i.2xlarge"`, `db_instance_class = "db.m6g.large"` — see [`examples/hb-pro-ha`](modules/ha-hot-hot/aws/examples/hb-pro-ha) |
| `HB-SCALE` | Consortium / national scale (500k+ users) | 48 (6 × 8) | `unlimited-scale/aws` | `instance_type = "m6i.2xlarge"`, `asg_min_size = asg_desired_capacity = 6`, `asg_max_size = 12`, `db_instance_class = "db.r6g.2xlarge"`, `redis_node_type = "cache.m6g.large"` — see [`examples/hb-scale`](modules/unlimited-scale/aws/examples/hb-scale) |

Azure equivalents by VM size: `Standard_D8s_v5` (8 vCPU) for the
`m6i.2xlarge` rows, `Standard_D4s_v5` for `m6i.xlarge`,
`Standard_D16s_v5` for `m6i.4xlarge`.

Notes:

- **`HB-SCALE` is a partner-desk SKU**, not on the standard four-plan
  price list — at the $0.24/vCPU-hr meter, 48 vCores is ~$8,400/mo of
  metering alone, so it's always quoted as a custom agreement.
  It matches the documented HB-SCALE-class operational profile in
  `hailbytes-sat/docs/DATABASE_OPS.md` (50+ vCPU, 200-connection pool,
  Postgres `max_connections ≥ 220`, one SMTP sending profile per member
  organization).
- SKU vCore counts assume steady state with auto-scaling off (the
  price-list default). Enabling auto-scaling meters the extra instances
  at the same per-vCore rate.
- These overrides change instance/DB classes — applying them to an
  existing deployment **replaces instances** (and can trigger an RDS
  scale operation). Plan a maintenance window; don't re-apply blindly.

## EU / data-residency pricing note

For EU/EEA-resident deployments (e.g. education-sector consortia): prices in
`eu-west-1` (Dublin, recommended default) and `eu-central-1`
(Frankfurt, fallback) are within roughly ±5% of `us-east-1`. The
procurement-grade column above holds in either region. All managed
services in the topology keep data in-region; the per-vCore meter
does not require any data to leave the customer VPC.

## Azure shapes (East US, pay-as-you-go, list price, rounded)

Azure parity of the three-shape AWS table. Cost lines are derived from
the per-module Azure READMEs and aligned at procurement-grade sizing
(same per-vCPU meter, same Multi-AZ / Zone-Redundant defaults). All
managed services in the topology keep data in-region.

| Shape | Module | Instances | Managed services | Infra | + per-vCore meter | **All-in (procurement-grade)** |
|---|---|---|---|---|---|---|
| **Single** | [`single-vm/azure`](modules/single-vm/azure) | 1× `Standard_D2s_v5` | none | ~$95/mo | 2 vCPU × 730h × $0.24 = ~$350/mo | **~$445/mo** |
| **HA hot-hot** | [`ha-hot-hot/azure`](modules/ha-hot-hot/azure) | 2× `Standard_D2s_v5` | Standard LB + Azure Cache Redis (Std C1) + Postgres Flex Server Zone-Redundant | ~$585/mo | 4 vCPU × 730h × $0.24 = ~$700/mo | **~$1,285/mo (≈ 2.9× single)** |
| **Unlimited scale** | [`unlimited-scale/azure`](modules/unlimited-scale/azure) | 3× `Standard_D2s_v5` (VMSS min) | Standard LB + Azure Cache Redis + Postgres Flex Server primary + 2× replicas (`GP_Standard_D4ds_v5`) | ~$1,480/mo | 6 vCPU × 730h × $0.24 = ~$1,050/mo | **~$2,530/mo at min, ~$5,150/mo at 10 instances** |

Cross-cloud parity is intentional: an AWS HA deployment and an Azure HA
deployment of the same product land within ~6% of each other at
procurement-grade sizing (AWS HA $1,215, Azure HA $1,285). The
delta is driven by Premium SSD vs gp3 and ALB-vs-Standard-LB pricing,
not by topology choices. Quote whichever cloud the customer's
finance team already has commitments with.

### Azure Cache for Redis sizing

Same role as AWS ElastiCache: shared session store + worker-lock
heartbeat. SKU + capacity scale together; **Basic is single-node and
rejected by module validation**.

| SKU / capacity | RAM | Per-month | Use case |
|---|---|---|---|
| Standard C1 | 1 GB | ~$55 | HA hot-hot or VMSS up to 5 instances |
| Standard C2 | 2.5 GB | ~$110 | VMSS 5–10 instances |
| Standard C3 | 6 GB | ~$220 | VMSS 10–20 instances |
| Premium P1 | 6 GB | ~$420 | Zone-redundant primary; needed for ≥3-zone deployments or Redis persistence |

## When prices change

1. Update the canonical AWS table in `hailbytes-sat/docs/AWS_HA_DEPLOYMENT.md § Estimated monthly cost`.
2. Mirror the AWS change in the AWS rows above and the AWS meter table.
3. Update Azure rows if the change is cross-cloud (SKU sizing, meter
   rate). Azure-only price drifts can be tracked in the per-module
   Azure READMEs first, then synced here on the next cycle.
4. Spot-check per-module READMEs (`modules/single-vm/{aws,azure}/README.md`,
   `modules/ha-hot-hot/{aws,azure}/README.md`,
   `modules/unlimited-scale/{aws,azure}/README.md`) — only edit them
   if the **Starter default** sizing changed; the procurement-grade
   column should already link here.
