# Azure Cost Shapes — HailBytes Terraform Modules

> Procurement-grade companion to [`COST_SHAPES.md`](COST_SHAPES.md) (which is
> AWS-first; its "Azure shapes" section is an East US summary, superseded for
> North Europe by this file). Region: **North Europe (Dublin, `northeurope`)**.
> Currencies: **EUR and USD**.
>
> **Every Azure infrastructure figure below was pulled from the Azure Retail
> Prices API** (`https://prices.azure.com/api/retail/prices`,
> `armRegionName eq 'northeurope'`, `type eq 'Consumption'`, list /
> pay-as-you-go, Linux) **on 2026-07-26**. Unit prices are reproducible — the
> query for each meter is given in [Reproducing these numbers](#reproducing-these-numbers).
> Monthly figures are `unit price × 730 h`.
>
> **Every fixed monthly charge in this document is verified.** The only figures
> left open are genuinely usage-dependent (outbound data transfer, NAT data
> processed, backup volume) — those get a rate card and worked examples in
> [Usage-dependent charges](#usage-dependent-charges) rather than a guess.
> Subtotals below are labelled **fixed monthly infrastructure** and are
> complete for a running deployment at rest.

---

## The three shapes (North Europe, pay-as-you-go, list price)

A "shape" is the topology — single VM, HA two-node, or horizontally-scaling
VM Scale Set. The three are not interpolatable: don't quote "2× a single VM"
for HA.

> **⚠️ These rows are sized at 2 vCPU per app node, which is BELOW the module
> default as of 2026-08-06.** Every module now defaults to the 8-vCore training
> floor (`Standard_D8s_v5`), because any instance serving training content or
> running the recurring automations carries an 8-vCore floor and training ships
> with the phish server. 2 vCPU is valid only for phishing-simulation-only
> deployments, and it is not a purchasable rung in any case — the marketplace
> floor is 8 vCPU. The infrastructure figures below remain verified against the
> Azure Retail Prices API at the sizing shown; the **meter** column is exact at
> any size (`metered vCores × 730h × $0.24`). Re-verify the infrastructure
> column at `Standard_D8s_v5` before quoting an all-in total.

All rows use **`Standard_D2s_v5` (2 vCPU)** as the app-VM size, the
procurement-grade equivalent of the AWS table's `m6i.large`. It is also the
module default on Azure, so — unlike the AWS table — the Azure procurement
sizing and the starter defaults coincide at this tier.

| Shape | Module | App instances | Managed services | Infra (verified) | + per-vCPU meter | **All-in** |
|---|---|---|---|---|---|---|
| **Single** | [`single-vm/azure`](modules/single-vm/azure) | 1× `Standard_D2s_v5` | NAT Gateway | €144 / $164 | 2 vCPU → €308 / $350 | **€451 / $514** |
| **HA hot-hot** | [`ha-hot-hot/azure`](modules/ha-hot-hot/azure) | 2× `Standard_D2s_v5` | Standard LB + Azure Cache for Redis (Standard C1) + PostgreSQL Flexible Server `GP_Standard_D2ds_v5` **ZoneRedundant HA** | €642 / $732 | 4 vCPU → €615 / $701 | **€1,257 / $1,432** |
| **HA hot-hot, self-managed DB** (`db_mode = "vm"`) | [`ha-hot-hot/azure`](modules/ha-hot-hot/azure) | 2× app + 1× `Standard_D2s_v5` DB VM | Standard LB + Redis Standard C1 | €467 / $532 | 4 vCPU → €615 / $701 | **€1,082 / $1,232** |
| **Unlimited scale** | [`unlimited-scale/azure`](modules/unlimited-scale/azure) | 2× `Standard_D2s_v5` (VMSS min) | Standard LB + Redis Standard C1 + Flexible Server `GP_Standard_D4ds_v5` ZoneRedundant primary + 2 read replicas | €1,486 / $1,694 | 4 vCPU → €615 / $701 | **€2,101 / $2,395 at min** |

### Single-instance → HA multiplier

**≈ 2.8× in both currencies** (€1,257 / €451 = 2.79; $1,432 / $514 = 2.79).

The AWS doc's equivalent multiplier is also **2.8×**. The two clouds land
within ~1% of each other on the multiplier, which is the number procurement actually
argues about — the absolute all-in figures differ more (see
[Cross-cloud comparison](#cross-cloud-comparison)).

The multiplier is *not* 2× because HA adds three things a single VM has none
of: a zone-redundant database (which bills the standby at full compute +
storage), a shared Redis, and a load balancer. It is *not* 6× either — the
figure ARCHITECTURE.md quotes for the HA tier ("~6× cost of single-vm") is
wrong at these SKUs and should be corrected to ~2.8×.

---

## Line-item breakdown

### Shape 1 — Single (`single-vm/azure`)

Module defaults: `Standard_D2s_v5`, 64 GiB Premium_LRS OS disk, 256 GiB
Premium_LRS data disk, `associate_public_ip = false` (a public IP is priced
here because a standalone VM needs an ingress path).

| Component | Quantity | Unit price | EUR/mo | USD/mo |
|---|---|---|---|---|
| VM `Standard_D2s_v5` (Linux) | 730 h | €0.0939 / $0.107 per h | 68.55 | 78.11 |
| OS disk, Premium SSD P6 (64 GiB) | 1 | €8.96 / $10.21 per mo | 8.96 | 10.21 |
| Data disk, Premium SSD P15 (256 GiB) | 1 | €33.36 / $38.01 per mo | 33.36 | 38.01 |
| Public IP, Standard static IPv4 | 730 h | €0.0044 / $0.005 per h | 3.21 | 3.65 |
| NAT Gateway (required for outbound; see A4) | 730 h | €0.0395 / $0.045 per h | 28.84 | 32.85 |
| Backup Storage Account, Cool ZRS | ~60 GB of bundles | €0.011 / $0.0125 per GB-mo | ~1 | ~1 |
| **Fixed monthly infrastructure** | | | **€143.91** | **$163.83** |
| HailBytes per-vCPU Marketplace meter | 2 vCPU × 730 h | $0.24 per vCPU-h | 307.5 🔸 | 350.40 |
| **All-in (at rest)** | | | **€451.4** | **$514.2** |

🔸 EUR meter figures are converted, not quoted by Azure — see
[The per-vCPU Marketplace meter](#the-per-vcpu-marketplace-meter).

### Shape 2 — HA hot-hot (`ha-hot-hot/azure`, `db_mode = "flexible_server"`)

Module defaults: 2× `Standard_D2s_v5` pinned to zones 1 and 2, 64 GiB
Premium OS disk + 256 GiB Premium data disk each, Standard Load Balancer with
one HTTPS rule, Azure Cache for Redis `Standard C1`, PostgreSQL Flexible
Server `GP_Standard_D2ds_v5` (2 vCore) with `high_availability.mode =
"ZoneRedundant"` and 128 GiB storage, Key Vault Standard.

| Component | Quantity | Unit price | EUR/mo | USD/mo |
|---|---|---|---|---|
| VMs `Standard_D2s_v5` (Linux) | 2 × 730 h | €0.0939 / $0.107 per h | 137.09 | 156.22 |
| OS disks, Premium SSD P6 (64 GiB) | 2 | €8.96 / $10.21 per mo | 17.91 | 20.41 |
| Data disks, Premium SSD P15 (256 GiB) | 2 | €33.36 / $38.01 per mo | 66.72 | 76.02 |
| Public IP, Standard static IPv4 (LB frontend) | 730 h | €0.0044 / $0.005 per h | 3.21 | 3.65 |
| Azure Cache for Redis, Standard C1 (1 GB, primary + replica) | 730 h | €0.1211 / $0.138 per h | 88.40 | 100.74 |
| Flexible Server compute, GP Ddsv5 `2 vCore` SKU, **×2 for ZoneRedundant HA** | 2 servers × 730 h | €0.1738 / $0.198 per h (whole 2-vCore SKU) | 253.75 | 289.08 |
| Flexible Server storage, **×2 for ZoneRedundant HA** | 2 × 128 GiB | €0.111 / $0.1265 per GB-mo | 28.42 | 32.38 |
| Key Vault Standard operations | ~nominal | €0.0263 / $0.03 per 10k ops | ~1 | ~1 |
| Standard Load Balancer, base (covers the first 5 rules; module creates 1) | 730 h | €0.0219 / $0.025 per h | 15.99 | 18.25 |
| NAT Gateway, base (required for outbound; see A4) | 730 h | €0.0395 / $0.045 per h | 28.84 | 32.85 |
| Backup Storage Account, Cool ZRS | ~60 GB of bundles | €0.011 / $0.0125 per GB-mo | ~1 | ~1 |
| **Fixed monthly infrastructure** | | | **€642.33** | **$731.61** |
| HailBytes per-vCPU Marketplace meter | 4 vCPU × 730 h | $0.24 per vCPU-h | 615.0 🔸 | 700.80 |
| **All-in (at rest)** | | | **€1,257.3** | **$1,432.4** |

**The single largest line is the database, not the VMs.** ZoneRedundant HA
doubles both compute and storage: €282 / $321 per month, versus €141 / $161
for the same server without HA.

**`db_high_availability_mode = "SameZone"` is not a cost saving.** Azure bills
2× compute and 2× storage for *both* HA modes — SameZone buys a lower-latency
standby and a lower SLA at the same price. (An earlier revision of this document
said it halved the line; that was wrong.) The levers that actually move this
line are reserved capacity and right-sizing — see
[Reducing the customer's Azure bill](#reducing-the-customers-azure-bill).

### Shape 2b — HA hot-hot with self-managed Postgres (`db_mode = "vm"`)

Replaces the Flexible Server with a third `Standard_D2s_v5` running
apt-installed PostgreSQL 16 on a 256 GiB Premium data disk.

| Component | EUR/mo | USD/mo |
|---|---|---|
| 2× app VM + disks + public IP (as above) | 224.93 | 256.30 |
| Azure Cache for Redis, Standard C1 | 88.40 | 100.74 |
| DB VM `Standard_D2s_v5` | 68.55 | 78.11 |
| DB VM OS disk P4 (30 GiB) + data disk P15 (256 GiB) | 37.99 | 43.29 |
| Key Vault | ~1 | ~1 |
| Standard Load Balancer base + NAT Gateway base + backup storage | 45.83 | 52.10 |
| **Fixed monthly infrastructure** | **€466.70** | **$531.55** |
| HailBytes per-vCPU meter (4 vCPU — the 2 app VMs only; the DB VM does **not** meter) | 615.0 🔸 | 700.80 |
| **All-in (at rest)** | **€1,082** | **$1,232** |

**Corrected 2026-08-06: this row previously metered 6 vCPU on the claim that
the DB VM carries the meter. It does not.**
`azurerm_linux_virtual_machine.db_vm` boots a `Canonical / ubuntu-24_04-lts`
`source_image_reference` with **no `plan {}` block** — it is plain Ubuntu with
apt-installed PostgreSQL 16, provisioned by
`hailbytes-init-postgres.sh`. Only the application VMs reference
`local.plan`, and the meter attaches to the Marketplace plan. The AWS
equivalent is the same: `aws_instance.db_ec2` uses `data.aws_ami.ubuntu`, not
the Marketplace AMI. The old figure over-stated the customer's licence cost by
$350/mo on this shape.

So this mode is **cheaper infrastructure and cheaper overall** — the earlier
"more expensive overall" inversion was an artifact of the metering error. What
you actually give up is managed backups, point-in-time restore and automatic
failover, which is the real reason to choose it deliberately rather than
to save money.

### Shape 3 — Unlimited scale (`unlimited-scale/azure`)

Module defaults: VMSS min/default 3 × `Standard_D2s_v5` across zones 1–3
(OS disk inherits the image size, ~30 GiB Premium; no data disks — instances
are stateless), Redis `Standard C1`, Flexible Server `GP_Standard_D4ds_v5`
(4 vCore) ZoneRedundant with 256 GiB storage, plus `db_replica_count = 2`
read replicas at the same SKU (replicas are single-zone; the module does not
set HA on them).

| Component | Quantity | Unit price | EUR/mo | USD/mo |
|---|---|---|---|---|
| VMSS instances `Standard_D2s_v5` | 3 × 730 h | €0.0939 / $0.107 per h | 205.64 | 234.33 |
| VMSS OS disks, Premium SSD P4 (~30 GiB) | 3 | €4.63 / $5.28 per mo | 13.90 | 15.84 |
| Public IP, Standard static IPv4 | 730 h | €0.0044 / $0.005 per h | 3.21 | 3.65 |
| Azure Cache for Redis, Standard C1 | 730 h | €0.1211 / $0.138 per h | 88.40 | 100.74 |
| Flexible Server primary compute, GP Ddsv5 `4 vCore` SKU **×2 (ZoneRedundant)** | 2 servers × 730 h | €0.3475 / $0.396 per h | 507.35 | 578.16 |
| Flexible Server primary storage **×2 (ZoneRedundant)** | 2 × 256 GiB | €0.111 / $0.1265 per GB-mo | 56.83 | 64.77 |
| 2× read replica compute, `4 vCore` SKU each | 2 servers × 730 h | €0.3475 / $0.396 per h | 507.35 | 578.16 |
| 2× read replica storage | 2 × 256 GiB | €0.111 / $0.1265 per GB-mo | 56.83 | 64.77 |
| Key Vault Standard | | | ~1 | ~1 |
| Standard Load Balancer base + NAT Gateway base + backup storage | | | 45.83 | 52.10 |
| **Fixed monthly infrastructure** | | | **€1,486.34** | **$1,693.51** |
| HailBytes per-vCPU meter at VMSS min | 6 vCPU × 730 h | $0.24 per vCPU-h | 922.5 🔸 | 1,051.20 |
| **All-in at `vmss_min_count = 3`** | | | **€2,409** | **$2,745** |
| **All-in at 10 instances** (meter 20 vCPU; +7 VM + OS disk) | | | **€5,074** | **$5,781** |

At `vmss_max_count = 20` (the module default ceiling) the meter alone is
40 vCPU × 730 h × $0.24 = **$7,008/mo**. Cap `vmss_max_count` to the number
the customer has actually budgeted for; the autoscaler will otherwise happily
buy metered capacity.

---

## The per-vCPU Marketplace meter

The HailBytes per-vCPU Marketplace meter — **$0.24 per vCPU-hour** — is the
largest single line in every shape above except unlimited-scale, where the
database overtakes it. It scales with **instance count**, not topology.

| Azure VM size | vCPU | Per month (24/7) USD | Per month (24/7) EUR 🔸 |
|---|---|---|---|
| `Standard_D2s_v5` | 2 | $350.40 | €307.5 |
| `Standard_D4s_v5` | 4 | $700.80 | €615.0 |
| `Standard_D8s_v5` | 8 | $1,401.60 | €1,230.0 |
| `Standard_D16s_v5` | 16 | $2,803.20 | €2,460.1 |

🔸 **The $0.24/vCPU-hour rate is USD-denominated and is the only authoritative
figure.** Azure Marketplace bills the customer in their billing currency using
Microsoft's own conversion, which this repo cannot see. The EUR column is
converted at **0.8776 EUR/USD**, which is not an FX quote — it is the ratio
implied by Azure's own EUR and USD list prices for the identical meters
(`Standard_D2s_v5`: €0.0939 / $0.107 = 0.8776; Flexible Server 2 vCore:
€0.1738 / $0.198 = 0.8778; Redis C1: €0.1211 / $0.138 = 0.8775; P6 disk:
€8.9574 / $10.207 = 0.8776). Treat the EUR meter column as indicative to
±2% and quote the USD rate in contracts unless the account team has a
Microsoft-confirmed EUR rate. 🚩

For customers on a Microsoft Azure Consumption Commitment (MACC) or an
Enterprise Agreement, the account team can quote a private-offer rate on the
meter; the list rate above is the procurement starting point.

### The fixed annual channel SKUs are the same number as the meter

The channel price list quotes a **fixed annual price per product** for each
plan instead of a usage meter. Those prices are the $0.24/vCPU-hour meter
annualised at 730 h/month and rounded down to a clean figure — **each plan
matches its metered equivalent to within 0.1%.**

| SKU | Plan | Metered vCores | Fixed list price | Meter equivalent (vCores × 8760 h × $0.24) | Δ |
|---|---|---|---|---|---|
| `HB-ESS` | Essential | 8 | $16,800/yr · $1,400/mo | $16,819/yr | −0.1% |
| `HB-PRO` | Professional | 16 | $33,600/yr · $2,800/mo | $33,638/yr | −0.1% |
| `HB-PRO-HA` | Professional HA | 16 (2 × 8) | $33,600/yr · $2,800/mo | $33,638/yr | −0.1% |
| `HB-SCALE` | Consortium / national scale | 48 (6 × 8) | partner-desk quote | $100,915/yr | — |

List prices are USD, per product (SAT **or** ASM), per year; both products
together are quoted as a bundle at the combined plan level. Confirm against the
current price schedule before quoting — the copy these figures come from is a
point-in-time snapshot, and the partner desk owns the live version.

Two consequences worth stating to a customer:

- **Moving between marketplace metering and a catalog SKU does not change the
  software price.** The SKU is a procurement convenience — one fixed annual
  line item instead of a usage meter — not a different rate. That is a useful
  thing to be able to say plainly in a public-sector procurement.
- **The plan price and the Azure infrastructure bill are separate, and the
  customer pays Azure directly.** Every plan is BYOC — installation into the
  customer's own AWS or Azure account — so the plan price never includes VMs,
  disks, the database, Redis, or the load balancer. The next section is the
  part finance actually asks about.

---

## SKU → Azure sizing and total first-year cost

This is the table to quote from for a new Azure customer. Sizing follows the
`COST_SHAPES.md` § *Simplified SKUs → module configuration* mapping, converted
to Azure VM sizes (`Standard_D8s_v5` for the 8-vCPU rows, `Standard_D4s_v5` for
4 vCPU, `Standard_D16s_v5` for 16 vCPU). Infrastructure is computed from the
verified North Europe unit prices in this document.

| SKU | Module + sizing | Azure infra €/mo | Azure infra $/mo | Azure infra $/yr | Plan $/yr | **All-in $/yr** | Infra share |
|---|---|---|---|---|---|---|---|
| `HB-ESS` | `single-vm/azure`, 1× `Standard_D8s_v5` | €350 | $398 | $4,778 | $16,800 | **$21,578** | 22% |
| `HB-PRO` | `single-vm/azure`, 1× `Standard_D16s_v5` | €624 | $711 | $8,527 | $33,600 | **$42,127** | 20% |
| `HB-PRO-HA` | `ha-hot-hot/azure`, 2× `Standard_D8s_v5`, module-default `GP_Standard_D2ds_v5` ZR | €1,054 | $1,200 | $14,403 | $33,600 | **$48,003** | 30% |
| `HB-PRO-HA` | same, DB upsized to `GP_Standard_D4ds_v5` (the Azure analogue of the AWS mapping's `db.m6g.large`) | €1,307 | $1,489 | $17,872 | $33,600 | **$51,472** | 35% |
| `HB-SCALE` | `unlimited-scale/azure`, 6× `Standard_D8s_v5`, `MO_Standard_E8ds_v5` ZR + 2 replicas, Redis Standard C3 | €5,088 | $5,798 | $69,572 | ~$100,915 🔸 | **~$170,487** | 41% |

🔸 `HB-SCALE` has no list price — it is always a custom agreement. The figure
shown is the metered equivalent at 48 vCores, for scale only.

Infra figures are the **complete fixed monthly cost** — VMs, disks, public IP,
Redis, database, Key Vault, Standard Load Balancer base, NAT Gateway base and
backup storage — at rest. Add traffic from the
[rate card](#usage-dependent-charges), and subtract reservations from
[Reducing the customer's Azure bill](#reducing-the-customers-azure-bill).

### What this changes about how we quote

1. **Azure infra is 20–48% of the first-year cost, and the spread is driven by
   topology, not by size.** `HB-PRO` (16 vCore, single VM) carries $8.5k of
   Azure; `HB-PRO-HA` (the same 16 vCore, two VMs) carries $14.4–17.9k. Quoting
   the plan price alone understates a customer's first-year spend by a fifth to
   nearly a half. Give finance the all-in column.

2. **`HB-STD` IS RETIRED as of 2026-08-06 — it can no longer be quoted at all,
   which supersedes the analysis in this item.** It was a 12-metered-vCore SKU,
   and no general-purpose shape exists at 12 vCores on either cloud; it was only
   reachable as 3 × 4-vCore nodes, each below the 8-vCore training floor. The
   cost profile below is retained because it is verified data about that shape,
   and because the read-replica point it makes generalises to any small VMSS.
   Historically: at
   48%, Azure costs nearly as much as the plan. The cause is the
   `unlimited-scale` module's default `db_replica_count = 2`: two
   `GP_Standard_D4ds_v5` read replicas add **€564/$643 per month ($7,715/yr)**
   in compute + storage on top of an already zone-redundant primary. A
   12-vCore, three-instance deployment rarely needs two read replicas. Setting
   `db_replica_count = 1` takes `HB-STD` all-in to **$44,477/yr**; `= 0` takes
   it to **$40,619/yr** — a 16% reduction in the customer's total cost with no
   change to the metered capacity they bought. Make the replica count a
   deliberate choice per deal rather than a default.

3. **`HB-PRO` vs `HB-PRO-HA` is a $5.9–9.3k/yr conversation, all of it Azure.**
   Both SKUs are the same 16 metered vCores and the same $33,600 plan price. The entire difference is infrastructure: a second VM, a shared Redis,
   and a zone-redundant database. That is the honest framing for "why does HA
   cost more if the licence is the same price" — and an easier conversation
   than the multiplier.

4. **The database, not the VMs, dominates every HA and autoscale row.** In
   `HB-PRO-HA`, the app VMs are $625/mo and the zone-redundant Flexible Server
   is $321/mo at default sizing, $611/mo upsized. In `HB-SCALE` the database
   (primary + 2 replicas, memory-optimised) is **$3,506 of the $5,746 monthly
   infra** — 61%. Any cost conversation that starts with VM size starts in the
   wrong place.

5. **`HB-PRO-HA` at 2 × 8 vCore does not match the module defaults.** The
   `ha-hot-hot/azure` default is `Standard_D2s_v5` (2 vCPU), so fulfilling this
   SKU means `vm_size = "Standard_D8s_v5"` — a 4× compute change. Applying that
   to a running deployment **replaces both VMs**; see
   [`docs/AZURE_PATCHING_AND_MIGRATION.md`](docs/AZURE_PATCHING_AND_MIGRATION.md#step-3--rolling-replace-one-vm-at-a-time)
   for the one-at-a-time procedure. Size correctly at first apply.

### Two price-list commitments the modules do not currently support

Both are worth resolving before the next public-sector deal, because they are
commitments in a channel catalog rather than internal notes:

- **GovCloud / Azure Government at price parity.** `CLAUDE.md` states that AWS
  GovCloud and Azure Government are **out of scope for v1**, and no module
  carries a GovCloud or Azure Government provider configuration, endpoint
  override, or region validation. The catalog commitment and the module scope
  disagree. For Azure Government the marketplace offer must additionally be
  published to the Azure Government marketplace — a separate Partner Center
  listing, not a Terraform change.
- **Optional auto-scaling, enabled on request.** True on
  `unlimited-scale/azure` (VMSS autoscale, `vmss_max_count` default 20). Not
  available on `single-vm` or `ha-hot-hot`, which is where `HB-ESS`, `HB-PRO`
  and `HB-PRO-HA` land — three of the four plans. If a customer on `HB-PRO`
  asks to turn auto-scaling on, the answer is a migration to a different module
  and topology, not a flag. Scaling out past the plan's vCore count also meters
  (or re-rates) the extra capacity.

---

## Azure Cache for Redis sizing

Same role as AWS ElastiCache: shared session store plus the worker-lock
heartbeat. **Basic is single-node and rejected by module validation** — it
breaks HA. Prices are the Standard-tier meter, which covers the primary and
replica pair.

| SKU / capacity | RAM | EUR/mo | USD/mo | Use case |
|---|---|---|---|---|
| Standard C1 | 1 GB | €88.40 | $100.74 | HA hot-hot, or VMSS up to ~5 instances (module default) |
| Standard C2 | 2.5 GB | €144.18 | $164.25 | VMSS 5–10 instances |
| Standard C3 | 6 GB | €288.28 | $328.50 | VMSS 10–20 instances |
| Premium P1 | 6 GB | €355.58 | $405.15 | Required for **explicit zone redundancy**, Redis persistence, or VNet injection |

> **Read this before quoting Standard as zone-redundant.** The Standard tier
> gives a primary/replica pair, but Azure only offers *zone redundancy* for
> Azure Cache for Redis on the **Premium** tier and above — and the module only
> sets `zones = ["1", "2"]` when `redis_sku_name = "Premium"`. A customer who
> asks "is every tier of the HA stack zone-redundant?" must be told **the
> default Redis is not**, and moved to Premium P1 (+€267 / +$304 per month over
> Standard C1) if they need it. The claim "Standard C1, zone-redundant
> primary/replica" in `modules/ha-hot-hot/azure/README.md` and in
> `COST_SHAPES.md` is incorrect and is tracked in the Azure HA parity audit.

> ⚠️ **Every price in this table is for a service Microsoft is retiring.**
> Azure Cache for Redis Basic/Standard/**Premium** retire **2028-09-30**;
> Enterprise/Enterprise Flash retire **2027-03-31**
> ([retirement FAQ](https://learn.microsoft.com/en-us/azure/azure-cache-for-redis/retirement-faq)).
> The successor is **Azure Managed Redis**.
>
> Three consequences for quoting:
>
> 1. **Don't sell the Premium P1 upgrade as the route to zone redundancy on a
>    multi-year term.** Azure Managed Redis is zone-redundant by default. Paying
>    €267/month extra for a capability the replacement service includes, on a
>    service that stops existing in 2028, is the wrong recommendation.
> 2. **Any Redis reservation must end before the retirement date.** Reservations
>    on this service are honoured only until then — 2028-09-30 for
>    Basic/Standard/Premium, 2027-03-31 for Enterprise. A 3-year Redis
>    reservation taken in 2026 runs past the Enterprise date.
> 3. **Azure Managed Redis is priced differently** — its SKUs are structured
>    directly on memory and performance rather than on capacity plus scale
>    factor, and it drops the Enterprise quorum node. The figures above do not
>    carry across; re-price against AMR before quoting anything that runs into
>    2028.
>
> The modules have not migrated yet. See
> [`docs/AZURE_HA_PARITY_AUDIT.md`](docs/AZURE_HA_PARITY_AUDIT.md#new-finding--azure-cache-for-redis-is-being-retired).

### What the successor costs

Verified against the Azure Retail Prices API, North Europe, same query as every
other figure in this document (`serviceName eq 'Redis Cache'`, `armRegionName eq
'northeurope'`). Azure Managed Redis Balanced SKUs are named for their memory in
GB, so the comparison is like-for-like on capacity.

| Capacity | Azure Cache for Redis (retiring) | Azure Managed Redis Balanced | Change |
|---|---|---|---|
| 1 GB | Standard C1 — $100.74/mo | **B1 — $25.55/mo** | **−75%** |
| 3 GB | *(no 3 GB SKU; C2 is 2.5 GB at $164.25)* | B3 — $52.56/mo | −68% at more RAM |
| 5–6 GB | Standard C3 (6 GB) — $328.50/mo | B5 (5 GB) — $125.56/mo | −62% |
| 6 GB, zone-redundant | Premium P1 — $405.15/mo | B5 — $125.56/mo (**zone-redundant by default**) | **−69%** |

Reserved pricing exists too: B1 is $199/year on a 1-year term ($16.58/mo, −35%),
B5 is $979/year.

The headline: **the cache line in every Azure shape in this document is roughly
4× what the successor service charges, and the $405.15 Premium P1 upgrade buys
zone redundancy that the successor includes at $125.56.** For the HA shape that
is $75/month of pure overpayment at the default, or $280/month if a customer was
quoted Premium for zone redundancy.

> **Two things here are not yet verified and should not be quoted as final:**
>
> 1. Microsoft documents a "non-HA option for dev/test and nonproduction at a
>    reduced cost", but the Retail Prices API publishes a **single** consumption
>    meter per Balanced SKU in North Europe — no HA/non-HA split. So it is not
>    established from pricing data alone whether $25.55 is the HA figure or
>    whether HA is a multiplier on top. Confirm before it reaches a quote.
> 2. Azure Managed Redis is **clustered by default**. SAT/ASM use Redis for
>    sessions and worker locks; whether those code paths are cluster-safe (no
>    cross-slot commands) has not been checked. A non-clustered AMR option
>    exists up to 25 GB, which is the conservative migration target.

---

## Application Gateway vs Standard Load Balancer

The modules default to a **Standard Load Balancer** (Layer 4, TCP passthrough
on 443). `enable_application_gateway = true` puts an Application Gateway v2 in
front, which is what unlocks TLS termination with a real certificate and
`waf_policy_id`. It is the AWS ALB-equivalent line item, and it is not cheap.

| Frontend | Fixed cost | Capacity units | EUR/mo at min 2 CU | USD/mo at min 2 CU |
|---|---|---|---|---|
| Standard Load Balancer (default) | €0.0219 / $0.025 per h | n/a (first 5 rules included) | €15.99 | $18.25 |
| Application Gateway **Standard_v2** (no WAF policy) | €0.2106 / $0.24 per h | €0.007 / $0.008 per CU-h | €163.96 | $186.88 |
| Application Gateway **WAF_v2** (`waf_policy_id` set) | €0.3791 / $0.432 per h | €0.0126 / $0.0144 per CU-h | €295.14 | $336.38 |

The module sets `autoscale_configuration { min_capacity = 2, max_capacity = 10 }`,
so 2 capacity units is the floor and 10 the ceiling; at max capacity the WAF_v2
capacity-unit line alone is €92 / $105 per month on top of the fixed cost.

**Adding WAF_v2 to the HA shape takes it from €1,257 / $1,432 to €1,552 /
$1,769 per month** (+23%). The Standard Load Balancer stays in the topology as
an L4 backend-pool member, so its €15.99 / $18.25 is additive, not replaced —
both lines are already in the shape subtotals. Quote WAF as a distinct option,
not as included.

At **18× the cost of the Standard Load Balancer**, App Gateway is the second
Azure line worth challenging after the database: if the customer already runs
Azure Front Door or their own reverse proxy with a real certificate, fronting
the module with that instead of enabling App Gateway saves €295 / $336 per
month. See [Reducing the customer's Azure bill](#reducing-the-customers-azure-bill).

---

## Usage-dependent charges

Every fixed monthly charge is in the subtotals above. What remains varies with
traffic, so it gets a **rate card** instead of a number. All rates verified
from the Retail Prices API for North Europe on 2026-07-26.

| Charge | Rate (EUR) | Rate (USD) | Notes |
|---|---|---|---|
| Internet egress, first 100 GB/mo | free | free | Per subscription, not per deployment. |
| Internet egress, 100 GB – 10 TB | €0.0702/GB | $0.08/GB | `Bandwidth - Routing Preference: Internet`, tiered. |
| Internet egress, 10 – 50 TB | €0.057/GB | $0.065/GB | |
| Internet egress, 50 – 150 TB | €0.0527/GB | $0.06/GB | |
| Internet egress, > 150 TB | €0.0351/GB | $0.04/GB | |
| **NAT Gateway data processed** | €0.0395/GB | $0.045/GB | **Charged on all traffic through the gateway, inbound and outbound, including traffic to Azure services.** Often larger than the egress line. |
| Standard LB data processed | €0.0044/GB | $0.005/GB | First 5 rules are covered by the base charge already in the subtotals. |
| Standard LB rule overage (> 5 rules) | €0.0088/h | $0.01/h | The modules create one rule, so this is zero unless you add listeners. |
| Inter-availability-zone data out | €0.0088/GB | $0.01/GB | Applies to cross-zone traffic; a zone-redundant topology generates some by design (VM↔DB standby, VM↔Redis replica). |
| Backup blob storage, Cool ZRS | €0.011/GB-mo | $0.0125/GB-mo | |
| Backup blob write ops | €0.0878/10k | $0.10/10k | A 20 GB bundle in 4 MiB blocks is ~5k writes. Negligible. |
| Backup blob read / retrieval | €0.0088/10k · €0.0088/GB | $0.01/10k · $0.01/GB | Only on restore. |
| Backup blob early delete (< 30 days in Cool) | €0.011/GB | $0.0125/GB | The immutability policy already pins bundles for 30 days by default, so this rarely triggers. |

### Worked examples

| Monthly traffic | Egress | NAT data processed | Total (USD) |
|---|---|---|---|
| 250 GB (small agency, `HB-ESS`) | $12.00 | $11.25 | **~$23** |
| 1 TB (`HB-PRO-HA` class) | $73.92 | $46.08 | **~$120** |
| 10 TB (large campaign month) | $809.10 | $460.80 | **~$1,270** |
| 30 TB (`HB-SCALE`, video-heavy) | $2,140.30 | $1,382.40 | **~$3,523** |

**Two things to design around, not just to price:**

1. **NAT data processing is charged on traffic to Azure's own services too.**
   The VMs talk to Key Vault, the backup Storage Account and (once fixed)
   Redis. Adding **service endpoints or private endpoints** for Storage and
   Key Vault keeps that traffic off the NAT Gateway entirely and off this line
   — a configuration change with no functional trade-off. Worth doing in the
   module.
2. **SAT serves training-module videos from the VM.** `content/M##/video.mp4`
   is baked into the image and streamed to learners, so egress scales with
   *learner count × modules watched*, not with admin activity. For a
   600k-learner rollout this is the single largest usage line and it deserves a
   real estimate from the customer's module plan — or a CDN / Azure Front Door
   in front of the media, which is cheaper per GB than raw VM egress at that
   volume. Model it explicitly; do not let it land as a surprise.

### Still open

| Item | Status |
|---|---|
| **EUR value of the $0.24/vCPU-hour meter** 🚩 | Marketplace meters bill in the customer's currency at Microsoft's conversion, which the retail price list does not expose. Quote USD, or get the EUR rate confirmed by the Microsoft account team. EUR figures here use the 0.8776 ratio implied by Azure's own dual-currency list prices. |
| **Premium SSD "Disk Mount" meters** | Azure publishes a second per-disk meter (e.g. `P15 LRS Disk Mount`, €1.92 / $2.19 per month) alongside the disk meter; its trigger condition was not confirmed. Worst case it adds ~€2.4 / $2.7 per month to an HA deployment — 0.2% of the total. Immaterial; verify on the first invoice. |
| **Log Analytics / Azure Monitor ingestion** | Nothing to price: the Azure modules create metric alerts (near-free) but no diagnostic settings and no workspace. That is a parity gap (B1/B2 in the audit), not a cost line — but closing it *will* add an ingestion charge, so re-price when it lands. |

---

## Reducing the customer's Azure bill

**Why this section exists.** HailBytes revenue is the plan price, which is fixed
at the licensed-VM vCore count. Azure infrastructure spend — the database above
all — goes entirely to Microsoft. Cutting it is therefore **revenue-neutral for
HailBytes and pure benefit to the customer**: a smaller total contract, an
easier budget approval, and a better-looking renewal, at no cost to us. Every
lever below is in that category unless flagged otherwise.

Ordered by saving per unit of effort.

### 1. Reserved capacity — the biggest lever, and nobody has to change anything

Azure reserved capacity applies to **PostgreSQL Flexible Server compute** and
to the **infrastructure portion of marketplace VMs** (the HailBytes software fee
is billed separately and is unaffected). Verified discounts for North Europe:

| Resource | 1-year reservation | 3-year reservation |
|---|---|---|
| Flexible Server compute (GP Ddsv5, MO Edsv5) | **−40%** | **−60%** |
| VMs (Dsv5 series) | **−38%** | **−60%** |
| Storage, Redis Standard, LB, NAT | not reservable | not reservable |

What that is worth per SKU, compute only:

| SKU | DB compute on-demand | 1-yr RI | 3-yr RI | VM compute on-demand | 1-yr RI | 3-yr RI | **3-yr total saving** |
|---|---|---|---|---|---|---|---|
| `HB-PRO-HA` (default DB) | $3,469 | $2,081 | $1,388 | $7,499 | $4,649 | $2,999 | **$6,580/yr** |
| `HB-PRO-HA` (upsized DB) | $6,938 | $4,163 | $2,775 | $7,499 | $4,649 | $2,999 | **$8,663/yr** |
| `HB-STD` (retired) | $13,876 | $8,326 | $5,550 | $5,624 | $3,487 | $2,250 | **$11,700/yr** |
| `HB-SCALE` | $38,964 | $23,379 | $15,586 | $22,496 | $13,947 | $8,998 | **$36,876/yr** |

`HB-SCALE` on 3-year reservations drops from **$69,572 to ~$32,696 of Azure per
year — a 53% cut** with no change to the topology, the plan price, or anything
the customer can see. This should be in every quote where the customer is
committing for a term anyway, and it is the first thing to raise when Azure
cost is the objection.

Caveats worth stating honestly: a reservation is a commitment (Azure allows
limited exchange/refund), it locks the SKU family and region, and it does not
cover storage. Reserve the steady-state floor, not the peak.

### 2. Right-size `db_replica_count` — the default is wrong for most deals

`unlimited-scale/azure` defaults to `db_replica_count = 2`. Each replica is a
full `GP_Standard_D4ds_v5` plus its own 256 GiB: **$321/mo, $3,858/yr each**.
On the retired `HB-STD` shape (three app instances) two read replicas was over-provisioned by
default:

| `db_replica_count` | Azure infra/yr | All-in/yr | vs default |
|---|---|---|---|
| 2 (module default) | $23,134 | $48,334 | — |
| 1 | $19,277 | $44,477 | **−$3,857** |
| 0 | $15,419 | $40,619 | **−$7,715 (−16%)** |

Make this a per-deal decision. The read-replica connection string is only used
if the application is configured to route reads to it.

### 3. Check whether `HB-SCALE` actually needs memory-optimised

`MO_Standard_E8ds_v5` is $811.76/mo per server against $578.16 for
`GP_Standard_D8ds_v5` — a 40% premium. Across the primary, its standby and two
replicas that is **$11,213/yr**. Memory-optimised is the right default only if
the workload is genuinely memory-bound; test with General Purpose first on a
non-production stack.

### 4. Right-size storage at first apply — it cannot be shrunk

Flexible Server storage can grow but **never shrink**. Day-1 over-provisioning
is permanent for the life of the server, and HA doubles it. Module defaults are
128 GiB (HA tier) and 256 GiB (autoscale tier); at 0.1265 $/GB-mo with the HA
doubling, 256 GiB costs $64.77/mo where 128 GiB costs $32.38. Start at the
smaller size with storage autogrow enabled and let it grow into the workload.

Same logic for `db_backup_retention_days` (module default 14, Azure minimum 7):
the free backup allowance equals 100% of provisioned storage, so retention only
costs money above that — but where it does, halving retention halves the charge.

### 5. Bring-your-own Postgres — now available

**Shipped.** `db_mode = "external"` on the HA tier (both clouds) connects the
stack to a Postgres server the customer already operates. The module provisions
no database at all; the customer supplies `external_db_host` and
`external_db_password`, TLS is enforced (`external_db_sslmode`, minimum
`require`), and the credentials land in the same Key Vault secret the other
modes use so the marketplace image bootstraps identically.

This mirrors the Redis escape hatch (`redis_endpoint_override` +
`enable_managed_redis = false`), which the HA module has always had.

For a customer who already operates Postgres at scale — which describes most
consortium and national-scale education buyers — this removes the entire
database line from their Azure bill: **$3,469–38,964/yr depending on SKU**, the
largest single saving available, and revenue-neutral for HailBytes because the
plan price is fixed at the licensed-VM vCore count.

**What the customer gives up:** zone-redundant failover, automated backups,
point-in-time restore and the pre-patch server snapshot all become theirs to
provide. The `db_is_customer_managed` output is `true` in this mode — check it
before repeating any backup or availability guarantee back to a customer, and
do not sell `HB-PRO-HA` on external mode unless their Postgres is genuinely
highly available.

Still on the roadmap for the autoscale tier, which has read replicas to
consider.

### 6. Keep NAT-bound traffic off the NAT Gateway

Service endpoints or private endpoints for the backup Storage Account and Key
Vault remove that traffic from the $0.045/GB NAT data-processing meter. Free to
implement, and it tightens the network posture at the same time.

### 7. Don't pay for App Gateway twice

WAF_v2 is €295 / $336 per month — 18× the Standard Load Balancer. If the
customer already runs Azure Front Door, an existing Application Gateway, or
their own reverse proxy with a valid certificate, fronting the module with that
(and leaving `enable_application_gateway = false`) delivers the same TLS and WAF
posture for nothing extra. Only stand up a second gateway when there is nothing
in front already.

### 8. Serve training video from a CDN, not from the VM

Specific to SAT at learner scale. `content/M##/video.mp4` is baked into the
image and streamed from the VM, so egress scales with learners × modules
watched. At `HB-SCALE` volumes that is the largest usage line in the whole bill
(see the [worked examples](#worked-examples)). Azure Front Door or any CDN in
front of the media is materially cheaper per GB at tens of terabytes, and it
takes the load off the app tier at the same time.

### What is *not* a saving

- **`db_high_availability_mode = "SameZone"`.** Both HA modes bill 2× compute
  and 2× storage. SameZone trades SLA for latency, not cost.
- **`db_mode = "vm"`.** It removes the Flexible Server but adds a licensed VM.
  Under metered billing that *increases* the customer's total because the DB VM
  carries the per-vCPU meter; under a fixed plan it consumes vCores the customer
  has already paid for, and it gives up automated backups, PITR and
  zone-redundant failover. Choose it for compliance or BYO-DBA reasons, never
  for cost.
- **Dropping the Standard Load Balancer.** At $18.25/mo it is not worth
  discussing, and there is no HA topology without it.

---

## Cross-cloud comparison

| | AWS (`us-east-1`, from `COST_SHAPES.md`) | Azure (`northeurope`, verified here) |
|---|---|---|
| Single | ~$435/mo | $514/mo (€451) |
| HA hot-hot | ~$1,215/mo | $1,432/mo (€1,257) |
| HA multiplier | ≈ 2.8× | ≈ 2.8× |
| Unlimited scale (min) | ~$2,250/mo | $2,745/mo (€2,409) |

Azure runs **roughly 18–22% higher** than the AWS list figures at the same
shape and vCPU count. Two caveats before using that as a cloud-selection
argument:

1. The AWS column is `us-east-1`; `COST_SHAPES.md` notes EU AWS regions run
   within ~±5% of it, so the like-for-like EU gap is smaller than the table
   implies.
2. The AWS column has **not** been re-verified against the AWS Price List API
   in this pass, and its Azure section understated the Flexible Server
   ZoneRedundant line (it quotes ~$260/mo for compute + storage where the
   verified figure is ~$321 for compute alone). It also omits NAT Gateway and
   load-balancer base charges, which the Azure column now includes — so part of
   the apparent gap is completeness, not price. Do not treat the AWS numbers as
   equally trustworthy until they get the same treatment.

The topology, security defaults, and per-vCPU meter are identical across
clouds. Quote whichever cloud the customer's finance team already has
commitments with — an Azure MACC or an AWS EDP moves the number far more than
the 10–19% list-price delta.

---

## EU data residency

North Europe (Dublin) keeps all managed-service data in-region: Flexible
Server (including the ZoneRedundant standby, which is pinned to a second zone
*within* the region), Azure Cache for Redis, managed disks, and the backup
Storage Account at `ZRS` (zone-redundant *within* North Europe — not
cross-region). `postgres_geo_redundant_backup_enabled` defaults to `false`, so
**no backup leaves the region unless the customer opts in**. Setting it to
`true` replicates backups to the paired region (West Europe) — confirm that is
acceptable under the customer's data-residency commitment before enabling it.

The per-vCPU meter is a billing event reported by the Azure platform; it moves
no customer data.

---

## Reproducing these numbers

Every unit price above comes from one unauthenticated HTTPS GET. Example — the
app VM:

```bash
curl -s "https://prices.azure.com/api/retail/prices?currencyCode=EUR&\$filter=\
armRegionName%20eq%20%27northeurope%27%20and%20\
serviceName%20eq%20%27Virtual%20Machines%27%20and%20\
armSkuName%20eq%20%27Standard_D2s_v5%27" | jq -r \
  '.Items[] | select(.type=="Consumption" and .productName=="Virtual Machines Dsv5 Series")
   | "\(.meterName)\t\(.retailPrice)\t\(.unitOfMeasure)"'
```

Swap `currencyCode=USD` for the dollar column. The other meters:

| Line | `$filter` predicate | Match on |
|---|---|---|
| App VM | `serviceName eq 'Virtual Machines' and armSkuName eq 'Standard_D2s_v5'` | `productName == "Virtual Machines Dsv5 Series"` (the `... Windows` product is the Windows price; exclude `Spot` / `Low Priority`) |
| Premium disks | `serviceName eq 'Storage' and skuName eq 'P15 LRS'` | `meterName == "P15 LRS Disk"` |
| Public IP | `serviceName eq 'Virtual Network'` | `meterName == "Standard IPv4 Static Public IP"` |
| Redis | `serviceName eq 'Redis Cache'` | `productName == "Azure Redis Cache Standard"`, `meterName == "C1 Cache"` (the 2-node total; `C1 Cache Instance` is per node) |
| Flexible Server compute | `serviceName eq 'Azure Database for PostgreSQL'` | `productName == "...General Purpose Ddsv5 Series Compute"`, `skuName == "2 vCore"` |
| Flexible Server storage | same | `meterName == "Storage Data Stored"` |
| Flexible Server backup | same | `meterName == "Backup Storage LRS Data Stored"` |
| Application Gateway | `serviceName eq 'Application Gateway'` | `productName == "Application Gateway WAF v2"` (note the separate `... WAF v2 - Discounted` product at a lower fixed cost — do not quote it unless the customer is eligible) |
| Key Vault | `serviceName eq 'Key Vault'` | `skuName == "Standard"`, `meterName == "Operations"` |
| **Standard Load Balancer** | `serviceName eq 'Load Balancer' and armRegionName eq 'Global'` | `meterName == "Standard Included LB Rules and Outbound Rules"`. **Note the region is `Global`, not `northeurope`** — a region-filtered query returns nothing, which is why this line was unverified in the first revision. |
| **NAT Gateway** | `serviceName eq 'NAT Gateway'` | `armRegionName == "Global"`, `meterName == "Standard Gateway"` and `"Standard Data Processed"` |
| Internet egress | `serviceName eq 'Bandwidth'` | `armRegionName == "northeurope"`, `productName == "Bandwidth - Routing Preference: Internet"`, `meterName == "Standard Data Transfer Out"` — tiered, read `tierMinimumUnits` |
| Backup blob storage | `serviceName eq 'Storage' and contains(productName, 'Blob')` | `productName == "General Block Blob v2"`, `skuName == "Cool ZRS"` (not the `Hierarchical Namespace` variant — the module does not enable HNS) |
| Reservations | any of the above | filter `type == "Reservation"` and read `reservationTerm`; the returned `retailPrice` is the **total for the whole term**, so divide by 1 or 3 to compare against an annualised on-demand figure |

Re-run before every procurement cycle; Azure list prices carry
`effectiveStartDate` / `effectiveEndDate` and do move.

---

## When prices change

1. Re-run the queries above for `northeurope` **and the `Global` region meters
   (Load Balancer, NAT Gateway)** in both currencies, and update the line-item
   tables.
2. Recompute the three shape subtotals, the SKU table, and the single→HA
   multiplier.
3. Update the per-module Azure READMEs
   (`modules/{single-vm,ha-hot-hot,unlimited-scale}/azure/README.md`) — they
   currently quote East US figures.
4. Reconcile with `COST_SHAPES.md`: its Azure section is East US and is
   superseded by this file for North Europe. If the per-vCPU meter rate itself
   changes, both files and the AWS meter table change together.
5. Re-check the reservation discounts in
   [Reducing the customer's Azure bill](#reducing-the-customers-azure-bill) —
   they are a percentage of list, so they move when list moves.
6. Keep the 🚩 list honest. If a figure gets verified, move it into a subtotal
   and say where the number came from.

## Related

- [`COST_SHAPES.md`](COST_SHAPES.md) — AWS shapes, the simplified-SKU mapping, and the canonical per-vCPU meter table
- [`docs/AZURE_HA_PARITY_AUDIT.md`](docs/AZURE_HA_PARITY_AUDIT.md) — what the Azure HA topology does and does not deliver today
- [`docs/AZURE_PATCHING_AND_MIGRATION.md`](docs/AZURE_PATCHING_AND_MIGRATION.md) — Azure rolling-patch runbook
- [`ARCHITECTURE.md`](ARCHITECTURE.md) — per-tier diagrams
