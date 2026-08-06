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

> **⚠️ This table is sized at 2 vCPU per node and is now BELOW the module
> defaults.** As of 2026-08-06 every module defaults to the 8-vCore training
> floor (`m6i.2xlarge` / `Standard_D8s_v5`), because any instance serving
> training content or running the recurring automations carries an 8-vCore
> floor — and training ships with the phish server. A 2-vCPU node is valid
> only for a phishing-simulation-only deployment, and 2 vCPU is not a
> purchasable rung in any case (the marketplace floor is 8 vCPU).
>
> The **meter** column below is exact. The **Infra** column is carried over
> from the earlier 2-vCPU verification against us-east-1 list prices and has
> **not** been re-verified at the 8-vCore default — do not quote the all-in
> figures until it is. Use the meter arithmetic, which holds at any size:
> `metered vCores × 730h × $0.24`.

| Shape | Module | Instances | Managed services | Infra (2-vCPU basis, re-verify) | + per-vCore meter | **All-in (unverified at new defaults)** |
|---|---|---|---|---|---|---|
| **Single** | [`single-vm/aws`](modules/single-vm/aws) | 1× `m6i.large` | none | ~$84/mo | 2 vCPU × 730h × $0.24 = ~$350/mo | **~$435/mo** |
| **HA hot-hot** | [`ha-hot-hot/aws`](modules/ha-hot-hot/aws) | 2× `m6i.large` | ALB + ElastiCache Multi-AZ + RDS Multi-AZ `db.m6g.large` | ~$515/mo | 4 vCPU × 730h × $0.24 = ~$700/mo | **~$1,215/mo (≈ 2.8× single)** |
| **HA hot-hot, self-managed DB** | [`ha-hot-hot/aws`](modules/ha-hot-hot/aws) with `db_mode = "ec2"` | 2× `m6i.large` app + 1× `m6i.large` DB | ALB + ElastiCache Multi-AZ | ~$345/mo | 4 vCPU × 730h × $0.24 = ~$700/mo | **~$1,045/mo (≈ 2.4× single)** |
| **Unlimited scale** | [`unlimited-scale/aws`](modules/unlimited-scale/aws) | 2× `m6i.large` (ASG min) | ALB + ElastiCache + RDS primary + 2 read replicas (`db.r6g.large`) | ~$1,200/mo | 4 vCPU × 730h × $0.24 = ~$700/mo | **~$1,900/mo at min** |

**The self-managed-DB row was over-metered and is corrected above.** It
previously counted 6 vCPU — 2 app nodes plus the DB node — for ~$1,050/mo.
The DB node does **not** carry the HailBytes meter: `aws_instance.db_ec2`
boots `data.aws_ami.ubuntu` (plain Canonical Ubuntu 24.04 + apt-installed
PostgreSQL 16), not the marketplace AMI, and the meter attaches to the
marketplace product code. The same is true on Azure, where
`azurerm_linux_virtual_machine.db_vm` uses a `Canonical / ubuntu-24_04-lts`
`source_image_reference` with no `plan {}` block, while the app VMs carry one.
Only nodes running the HailBytes marketplace image meter. That was a $350/mo
over-statement of the customer's licence cost on this shape.

**Metered vCores at the module defaults (8 vCore per node):** single = 8
(~$1,400/mo), HA pair = 16 (~$2,800/mo), auto-scaling at the 2-node baseline
= 16 (~$2,800/mo), each further node +8 (~$1,400/mo).

## Per-vCore meter (the big one)

The HailBytes per-vCore Marketplace meter — `$0.24/vCPU-hour` — is
typically the largest single line in HA and unlimited-scale deployments.
It scales with **instance count**, not topology, so doubling app
instances doubles the meter regardless of how much shared infra they
sit behind. Treat it as a first-class cost in every quote.

The portable ladder — every rung is a stock shape on both clouds at the same
4 GB-per-vCore ratio, and `variables.tf` now rejects anything off it at plan
time. Note there is **nothing between 16 and 32 vCPU on either cloud**, so a
24-vCore deployment cannot be built as one VM or as a symmetric pair.

| AWS instance type | Azure VM size | vCPU | Per-month per instance (24/7) |
|---|---|---|---|
| `m6i.large` | `Standard_B2s` / `Standard_D2s_v5` | 2 | $350 |
| `m6i.xlarge` | `Standard_D4s_v5` | 4 | $700 |
| `m6i.2xlarge` | `Standard_D8s_v5` | 8 | $1,400 |
| `m6i.4xlarge` | `Standard_D16s_v5` | 16 | $2,800 |
| `m6i.8xlarge` | `Standard_D32s_v5` | 32 | $5,610 |
| `m6i.12xlarge` | `Standard_D48s_v5` | 48 | $8,410 |
| `m6i.16xlarge` | `Standard_D64s_v5` | 64 | $11,210 |

The 2 and 4 vCPU rungs are phishing-simulation-only capacity and are not
purchasable plans; **8 vCPU is both the training floor and the commercial
entry rung**. `t3.large` was previously listed here and is no longer an
accepted value — it is a burstable T-family shape that is not on the ladder.

For deployments running Savings Plans or Enterprise Discount Program
(EDP) discounts on the meter, the account team can quote a custom
number — these list prices are the procurement starting point.

## Module defaults are now the 8-vCore floor

**Changed 2026-08-06, and this is a breaking change — see
[CHANGELOG](CHANGELOG.md).** Modules used to ship deliberately-small
"starter" defaults (`t3.large` / `Standard_D2s_v5`, 2 vCPU) so a fresh
`terraform apply` produced a cheap PoC. That is gone: every module now
defaults to the 8-vCore training floor, `m6i.2xlarge` on AWS and
`Standard_D8s_v5` on Azure.

The reason is that the old defaults shipped *below* a hard engineering floor.
Any instance serving training content or running the recurring automations
needs 8 vCores — learner video/SCORM streaming, certificate PDF rendering and
the one-minute automation sweep all contend with the co-located Postgres
below that — and training ships with the phish server, so it is the default
workload, not an add-on. A 2-vCPU default therefore built something we do not
support, and it matched no purchasable SKU either, since the marketplace floor
is 8 vCPU.

Two consequences to plan for:

- **`terraform apply` on an existing deployment that relied on the defaults
  will REPLACE the instances** and roughly quadruple both the infrastructure
  bill and the metered licence. Pin `instance_type` / `vm_size` explicitly
  before upgrading if you need the old sizing.
- **Off-ladder values are now rejected at plan time.** `instance_type` and
  `vm_size` carry `validation` blocks constraining them to the portable set
  (2, 4, 8, 16, 32, 48, 64 vCores). Anyone passing `t3.large`, an `m5.*`
  shape, or a would-be `Standard_D24s_v5` gets a plan-time error instead of
  discovering the problem at apply, or worse, on an invoice.

Only the HailBytes application nodes are constrained. `db_instance_class`,
`db_ec2_instance_type`, `db_vm_size` and `redis_node_type` stay free-form:
they are cloud infrastructure, not HailBytes-licensed capacity, and they do
not meter.

> No `v1.0.0` tag exists yet ([#48](https://github.com/HailBytes/hailbytes-terraform-modules/issues/48)); pin to a commit SHA instead of `?ref=v1.0.0` until a tagged release ships.

```hcl
module "hailbytes_sat_ha" {
  source = "github.com/hailbytes/hailbytes-terraform-modules//modules/ha-hot-hot/aws?ref=v1.0.0"

  # instance_type now defaults to m6i.2xlarge (8 vCore). One size variable is
  # applied to BOTH nodes by design, so an asymmetric pair is unexpressible:
  # a load balancer distributes by connection, not by capacity, so unequal
  # nodes take uneven shares and losing the larger one drops you to whatever
  # fraction the smaller was.
  db_instance_class = "db.m6g.large"   # default: db.t3.medium
  # redis_node_type already defaults to cache.t4g.small
  # ...
}
```

## Simplified SKUs → module configuration

The channel price list quotes fixed annual plans (the "simplified SKUs").
Each SKU's vCore count is the **total metered vCPU at steady state** —
`capacity × nodes` — and maps onto a module plus sizing overrides. The
8-vCore rungs need no override now that it is the default.

Sizing is **two independent decisions**: the capacity tier the roster needs,
and the topology (one VM, or a symmetric pair of two identical VMs). Because
the meter counts vCores rather than machines, a pair bills at exactly twice
its tier — so **HA costs exactly what the equivalent single-VM capacity
costs**, and each price point above the floor offers a real choice between
capacity and redundancy.

| SKU | Plan | List price (per product) | Metered vCores | Module | Overrides vs defaults |
|---|---|---|---|---|---|
| `HB-ESS` | Essential | $16,800/yr · $1,400/mo | 8 | `single-vm/aws` | none — 8 vCore is the default |
| `HB-PRO` | Professional | $33,600/yr · $2,800/mo | 16 | `single-vm/aws` | `instance_type = "m6i.4xlarge"` |
| `HB-PRO-HA` | Professional HA | $33,600/yr · $2,800/mo | 16 (2 × 8) | `ha-hot-hot/aws` | `db_instance_class = "db.m6g.large"` — see [`examples/hb-pro-ha`](modules/ha-hot-hot/aws/examples/hb-pro-ha) |
| `HB-ENTP` | Enterprise Plus | $67,300/yr · $5,610/mo | 32 | `single-vm/aws` | `instance_type = "m6i.8xlarge"` |
| `HB-ENTP-HA` ᵖ | Enterprise Plus HA | $67,300/yr · $5,610/mo | 32 (2 × 16) | `ha-hot-hot/aws` | `instance_type = "m6i.4xlarge"`, `db_instance_class = "db.m6g.large"` |
| `HB-MSP` ᵖ | MSP / Consortium | $100,900/yr · $8,410/mo | 48 | `single-vm/aws` | `instance_type = "m6i.12xlarge"` |
| `HB-MSP-L` ᵖ | MSP / Consortium (large) | $134,600/yr · $11,210/mo | 64 | `single-vm/aws` | `instance_type = "m6i.16xlarge"` |
| `HB-SCALE` | Auto-scaling | metered per node | 16 at the 2-node baseline, +8 per node | `unlimited-scale/aws` | `db_instance_class = "db.r6g.2xlarge"`, `redis_node_type = "cache.m6g.large"` for consortium-scale data tiers — see [`examples/hb-scale`](modules/unlimited-scale/aws/examples/hb-scale) |

ᵖ **Proposed SKU code — needs commercial sign-off before it reaches a price
list.** The three marked rows cover rungs that previously had no code.

**Retired SKUs.** `HB-STD` (12 vCores) and `HB-ENT` (24 vCores) are withdrawn:
neither Azure Dsv5 nor AWS m6i has a general-purpose shape at 12 or 24 vCPU,
and there is nothing at all between 16 and 32, so neither could be delivered as
one VM or as a symmetric pair. `HB-STD` was previously fulfilled as 3 ×
`m6i.xlarge` — three 4-vCore nodes, each below the 8-vCore training floor —
which is why it is not simply re-mapped. **Do not reuse either code for a
different vCore count**; a procurement system that has bought `HB-ENT` as 24
vCores must not silently receive 32.

**`HB-SCALE` is no longer a fixed node count.** It was specified as 48 metered
vCores at a 6 × 8 steady state, which picked an arbitrary point on a range. The
auto-scaling shape is a range of identical 8-vCore nodes — 2 at the default
baseline, up to `asg_max_size` — so the meter is `8 × instance count` and the
SKU is quoted from the baseline upward rather than at one snapshot.

Each fixed plan price is the meter annualised — `vCores × 8760 h × $0.24`,
rounded to the nearest $100 — so a customer moving between marketplace
metering and a catalog SKU sees no change in software price; only the billing
shape changes. (This replaces an earlier `vCores × 730 h × $0.24 × 12`
formulation that rounded the monthly figure before multiplying, which
understated the annual list by $100 at 32 and 48 vCores and more above that.)

Azure equivalents by VM size, across the whole portable ladder:
`Standard_D8s_v5` (8 vCPU) for `m6i.2xlarge`, `Standard_D16s_v5` for
`m6i.4xlarge`, `Standard_D32s_v5` for `m6i.8xlarge`, `Standard_D48s_v5` for
`m6i.12xlarge`, `Standard_D64s_v5` for `m6i.16xlarge`, and
`Standard_D4s_v5` for `m6i.xlarge` (4 vCPU, phishing-only).
For each SKU's **Azure infrastructure
cost and all-in first-year total**, see
[`AZURE_COST_SHAPES.md`](AZURE_COST_SHAPES.md#sku--azure-sizing-and-total-first-year-cost)
— Azure infra runs 19–47% of first-year cost depending on topology, so the
plan price alone is not a customer's total.

Notes:

- **`HB-SCALE` is a partner-desk SKU**, not on the standard price list. A
  consortium-scale fleet meters heavily — 48 metered vCores is ~$8,410/mo of
  metering alone, 64 is ~$11,210/mo — so it is always quoted as a custom
  agreement. It matches the documented HB-SCALE-class operational profile in
  `hailbytes-sat/docs/DATABASE_OPS.md` (50+ vCPU, 200-connection pool,
  Postgres `max_connections ≥ 220`, one SMTP sending profile per member
  organization). Note that a consortium running **training** sizes at 64
  vCores per `hailbytes-sat/docs/VM_SCALING.md`; 32 is the figure only where
  members run phishing simulation only.
- Fixed-plan vCore counts are a steady-state snapshot. `HB-SCALE` is the
  exception and is quoted as a range: the meter is `8 × instance count`, so
  scaling out meters the extra nodes at the same per-vCore rate.
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

> [!NOTE]
> **For North Europe, use [`AZURE_COST_SHAPES.md`](AZURE_COST_SHAPES.md)**,
> which carries EUR + USD figures pulled from the Azure Retail Prices API
> rather than derived from the module READMEs, and flags the line items that
> can't be verified. The table below is an East US summary; its Postgres
> Zone-Redundant line in particular understates the verified cost.

Azure parity of the three-shape AWS table. Cost lines are derived from
the per-module Azure READMEs and aligned at procurement-grade sizing
(same per-vCPU meter, same Multi-AZ / Zone-Redundant defaults). All
managed services in the topology keep data in-region.

| Shape | Module | Instances | Managed services | Infra | + per-vCore meter | **All-in (procurement-grade)** |
|---|---|---|---|---|---|---|
| **Single** | [`single-vm/azure`](modules/single-vm/azure) | 1× `Standard_D2s_v5` | none | ~$95/mo | 2 vCPU × 730h × $0.24 = ~$350/mo | **~$445/mo** |
| **HA hot-hot** | [`ha-hot-hot/azure`](modules/ha-hot-hot/azure) | 2× `Standard_D2s_v5` | Standard LB + Azure Cache Redis (Std C1, not zone-redundant) + Postgres Flex Server Zone-Redundant | ~$585/mo | 4 vCPU × 730h × $0.24 = ~$700/mo | **~$1,285/mo (≈ 2.9× single)** |
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
| Standard C1 | 1 GB | ~$101 | HA hot-hot or VMSS up to 5 instances. Primary/replica, **not** zone-redundant — that needs Premium. |
| Standard C2 | 2.5 GB | ~$164 | VMSS 5–10 instances |
| Standard C3 | 6 GB | ~$329 | VMSS 10–20 instances |
| Premium P1 | 6 GB | ~$405 | The only tier with zone redundancy; also needed for Redis persistence or VNet injection |

> ⚠️ **This whole table is a retiring service.** Azure Cache for Redis
> Basic/Standard/Premium retire **2028-09-30**; Enterprise **2027-03-31**. The
> successor, Azure Managed Redis, is zone-redundant by default and prices
> materially lower. Do not quote the Premium P1 upgrade as the route to zone
> redundancy on a term that runs past 2028. Full detail and the AMR comparison:
> [`AZURE_COST_SHAPES.md § Azure Cache for Redis sizing`](AZURE_COST_SHAPES.md#azure-cache-for-redis-sizing).

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
