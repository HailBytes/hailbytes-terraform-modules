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
> **Figures that could NOT be verified are marked 🚩 and are excluded from the
> subtotals.** They are not estimates; they are holes. Fill them before sending
> a quote to procurement. See [Unverified line items](#unverified-line-items).

---

## The three shapes (North Europe, pay-as-you-go, list price)

A "shape" is the topology — single VM, HA two-node, or horizontally-scaling
VM Scale Set. The three are not interpolatable: don't quote "2× a single VM"
for HA.

All rows use **`Standard_D2s_v5` (2 vCPU)** as the app-VM size, the
procurement-grade equivalent of the AWS table's `m6i.large`. It is also the
module default on Azure, so — unlike the AWS table — the Azure procurement
sizing and the starter defaults coincide at this tier.

| Shape | Module | App instances | Managed services | Infra (verified) | + per-vCPU meter | **All-in** |
|---|---|---|---|---|---|---|
| **Single** | [`single-vm/azure`](modules/single-vm/azure) | 1× `Standard_D2s_v5` | none | €114 / $130 | 2 vCPU → €308 / $350 | **€422 / $480** |
| **HA hot-hot** | [`ha-hot-hot/azure`](modules/ha-hot-hot/azure) | 2× `Standard_D2s_v5` | Standard LB 🚩 + Azure Cache for Redis (Standard C1) + PostgreSQL Flexible Server `GP_Standard_D2ds_v5` **ZoneRedundant HA** | €597 / $680 | 4 vCPU → €615 / $701 | **€1,212 / $1,380** |
| **HA hot-hot, self-managed DB** (`db_mode = "vm"`) | [`ha-hot-hot/azure`](modules/ha-hot-hot/azure) | 2× app + 1× `Standard_D2s_v5` DB VM | Standard LB 🚩 + Redis Standard C1 | €421 / $479 | 6 vCPU → €923 / $1,051 | **€1,343 / $1,531** |
| **Unlimited scale** | [`unlimited-scale/azure`](modules/unlimited-scale/azure) | 3× `Standard_D2s_v5` (VMSS min) | Standard LB 🚩 + Redis Standard C1 + Flexible Server `GP_Standard_D4ds_v5` ZoneRedundant primary + 2 read replicas | €1,441 / $1,641 | 6 vCPU → €923 / $1,051 | **€2,363 / $2,693 at min** |

### Single-instance → HA multiplier

**≈ 2.9× in both currencies** (€1,212 / €422 = 2.87; $1,380 / $480 = 2.87).

The AWS doc's equivalent multiplier is **2.8×**. The two clouds land within
~3% of each other on the multiplier, which is the number procurement actually
argues about — the absolute all-in figures differ more (see
[Cross-cloud comparison](#cross-cloud-comparison)).

The multiplier is *not* 2× because HA adds three things a single VM has none
of: a zone-redundant database (which bills the standby at full compute +
storage), a shared Redis, and a load balancer. It is *not* 6× either — the
figure ARCHITECTURE.md quotes for the HA tier ("~6× cost of single-vm") is
wrong at these SKUs and should be corrected to ~3×.

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
| **Infra subtotal** | | | **€114.08** | **$129.98** |
| HailBytes per-vCPU Marketplace meter | 2 vCPU × 730 h | $0.24 per vCPU-h | 307.5 🔸 | 350.40 |
| **All-in** | | | **€421.6** | **$480.4** |

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
| **Infra subtotal (verified meters only)** | | | **€596.50** | **$679.50** |
| Standard Load Balancer (rules + data processed) | | 🚩 unverified | — | — |
| NAT Gateway / outbound egress path | | 🚩 not provisioned by the module | — | — |
| Backup Storage Account (ZRS, Cool) + immutable blobs | | 🚩 usage-dependent | — | — |
| HailBytes per-vCPU Marketplace meter | 4 vCPU × 730 h | $0.24 per vCPU-h | 615.0 🔸 | 700.80 |
| **All-in** | | | **€1,211.5** | **$1,380.3** |

**The single largest line is the database, not the VMs.** ZoneRedundant HA
doubles both compute and storage: €282 / $321 per month, versus €141 / $161
for the same server without HA. `db_high_availability_mode = "SameZone"`
halves that line and lowers the SLA — it is the one lever that moves this
shape materially without touching the vCPU meter.

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
| **Infra subtotal (verified meters only)** | **€420.9** | **$479.4** |
| HailBytes per-vCPU meter (6 vCPU — the DB VM meters too) | 922.5 🔸 | 1,051.20 |
| **All-in** | **€1,343** | **$1,531** |

Cheaper infrastructure, **more expensive overall**: the DB VM is a HailBytes
Marketplace image, so it carries the per-vCPU meter. Same inversion as the AWS
`db_mode = "ec2"` row. Choose this mode for compliance/BYO-DBA reasons, never
to save money. It also gives up automated backups, zone-redundant failover,
and point-in-time restore.

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
| **Infra subtotal (verified meters only)** | | | **€1,440.5** | **$1,641.4** |
| HailBytes per-vCPU meter at VMSS min | 6 vCPU × 730 h | $0.24 per vCPU-h | 922.5 🔸 | 1,051.20 |
| **All-in at `vmss_min_count = 3`** | | | **€2,363** | **$2,693** |
| **All-in at 10 instances** (meter 20 vCPU; +7 VM + OS disk) | | | **€5,028** | **$5,729** |

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

| SKU | Plan | Metered vCores | Fixed list price | Meter equivalent (vCores × 730 h × $0.24 × 12) | Δ |
|---|---|---|---|---|---|
| `HB-ESS` | Essential | 8 | $16,800/yr · $1,400/mo | $16,819/yr | −0.1% |
| `HB-STD` | Standard | 12 | $25,200/yr · $2,100/mo | $25,229/yr | −0.1% |
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
| `HB-ESS` | `single-vm/azure`, 1× `Standard_D8s_v5` | €320 | $364 | $4,372 | $16,800 | **$21,172** | 21% |
| `HB-STD` | `unlimited-scale/azure`, 3× `Standard_D4s_v5`, `GP_Standard_D4ds_v5` ZR + 2 replicas | €1,646 | $1,876 | $22,509 | $25,200 | **$47,709** | **47%** |
| `HB-PRO` | `single-vm/azure`, 1× `Standard_D16s_v5` | €594 | $677 | $8,121 | $33,600 | **$41,721** | 19% |
| `HB-PRO-HA` | `ha-hot-hot/azure`, 2× `Standard_D8s_v5`, module-default `GP_Standard_D2ds_v5` ZR | €1,008 | $1,148 | $13,778 | $33,600 | **$47,378** | 29% |
| `HB-PRO-HA` | same, DB upsized to `GP_Standard_D4ds_v5` (the Azure analogue of the AWS mapping's `db.m6g.large`) | €1,261 | $1,437 | $17,247 | $33,600 | **$50,847** | 34% |
| `HB-SCALE` | `unlimited-scale/azure`, 6× `Standard_D8s_v5`, `MO_Standard_E8ds_v5` ZR + 2 replicas, Redis Standard C3 | €5,042 | $5,746 | $68,947 | ~$100,915 🔸 | **~$169,862** | 41% |

🔸 `HB-SCALE` has no list price — it is always a custom agreement. The figure
shown is the metered equivalent at 48 vCores, for scale only.

All infra figures **exclude the 🚩 items** (Standard Load Balancer, NAT Gateway,
backup storage, egress). They are floors. See
[Unverified line items](#unverified-line-items).

### What this changes about how we quote

1. **Azure infra is 19–47% of the first-year cost, and the spread is driven by
   topology, not by size.** `HB-PRO` (16 vCore, single VM) carries $8.1k of
   Azure; `HB-PRO-HA` (the same 16 vCore, two VMs) carries $13.8–17.2k. Quoting
   the plan price alone understates a customer's first-year spend by a fifth to
   nearly a half. Give finance the all-in column.

2. **`HB-STD` is the outlier and should be examined before it is quoted.** At
   47%, Azure costs nearly as much as the plan. The cause is the
   `unlimited-scale` module's default `db_replica_count = 2`: two
   `GP_Standard_D4ds_v5` read replicas add **€564/$643 per month ($7,715/yr)**
   in compute + storage on top of an already zone-redundant primary. A
   12-vCore, three-instance deployment rarely needs two read replicas. Setting
   `db_replica_count = 1` takes `HB-STD` all-in to **$43,851/yr**; `= 0` takes
   it to **$39,994/yr** — a 16% reduction in the customer's total cost with no
   change to the metered capacity they bought. Make the replica count a
   deliberate choice per deal rather than a default.

3. **`HB-PRO` vs `HB-PRO-HA` is a $5.7–9.1k/yr conversation, all of it Azure.**
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

---

## Application Gateway vs Standard Load Balancer

The modules default to a **Standard Load Balancer** (Layer 4, TCP passthrough
on 443). `enable_application_gateway = true` puts an Application Gateway v2 in
front, which is what unlocks TLS termination with a real certificate and
`waf_policy_id`. It is the AWS ALB-equivalent line item, and it is not cheap.

| Frontend | Fixed cost | Capacity units | EUR/mo at min 2 CU | USD/mo at min 2 CU |
|---|---|---|---|---|
| Standard Load Balancer (default) | 🚩 unverified | 🚩 unverified | 🚩 | 🚩 |
| Application Gateway **Standard_v2** (no WAF policy) | €0.2106 / $0.24 per h | €0.007 / $0.008 per CU-h | €163.96 | $186.88 |
| Application Gateway **WAF_v2** (`waf_policy_id` set) | €0.3791 / $0.432 per h | €0.0126 / $0.0144 per CU-h | €295.14 | $336.38 |

The module sets `autoscale_configuration { min_capacity = 2, max_capacity = 10 }`,
so 2 capacity units is the floor and 10 the ceiling; at max capacity the WAF_v2
capacity-unit line alone is €92 / $105 per month on top of the fixed cost.

**Adding WAF_v2 to the HA shape takes it from €1,212 / $1,380 to roughly
€1,507 / $1,717 per month** (+24%), before the unverified Standard LB line.
Quote WAF as a distinct option, not as included.

---

## Unverified line items

Per the instruction not to estimate silently, these are the figures this
document could **not** verify from the Azure Retail Prices API on 2026-07-26.
They are excluded from every subtotal above, so **each subtotal is a floor,
not a total**.

| 🚩 Item | Why unverified | What to do |
|---|---|---|
| **Standard Load Balancer** (hourly + rules + data processed) | No `Load Balancer` or matching `Virtual Network` meter is returned for `armRegionName eq 'northeurope'`. The region's `Virtual Network` service exposes only `IP Addresses`, `Public IP Prefix`, and `Global Virtual Network Peering`. | Read the figure off the Azure Pricing Calculator for North Europe, or off a real invoice, before quoting. Every shape in this doc includes a Standard LB. |
| **NAT Gateway / outbound egress** | Same: no `NAT Gateway` meter returned for the region. **Also: the Azure modules do not provision one at all** (`modules/network/azure` has no NAT Gateway, unlike `modules/network/aws`, which has one per AZ). | Two problems, one line. Price it *and* decide whether the module should create it — the app VMs have no outbound path without one. Tracked in the Azure HA parity audit. |
| **EUR value of the $0.24/vCPU-hour meter** | Marketplace meters bill in the customer's currency at Microsoft's conversion, which is not exposed in the retail price list. | Quote USD, or get the EUR rate confirmed by the Microsoft account team. The EUR figures here use the 0.8776 ratio implied by Azure's own dual-currency list prices. |
| **Backup Storage Account** (ZRS, Cool tier, blob versioning, immutability) | Cost is a function of bundle size × retention × version count, none of which is known ahead of a deployment. | Size it from the customer's expected DB + uploads volume. For a 600k-learner tenant this is not a rounding error. |
| **Outbound data transfer** | Depends entirely on campaign volume (SAT sends mail; ASM scans). | Model from the customer's expected send volume. |
| **Premium SSD "Disk Mount" meters** | Azure publishes a second per-disk meter (e.g. `P15 LRS Disk Mount`, €1.92/mo) alongside the disk meter. Its exact applicability to an attached, running disk was not confirmed. | Verify against an invoice. If it applies, add ~€2.4 / $2.7 per month per HA deployment — immaterial, but don't be surprised by it. |
| **Log Analytics / Azure Monitor ingestion** | The Azure modules create metric alerts (which are near-free) but no diagnostic settings or Log Analytics workspace, so there is nothing to price — and equally, no LB access logs or flow logs, unlike AWS. | Note the observability gap to the customer; it is a parity gap, not a cost line. |

---

## Cross-cloud comparison

| | AWS (`us-east-1`, from `COST_SHAPES.md`) | Azure (`northeurope`, verified here) |
|---|---|---|
| Single | ~$435/mo | $480/mo (€422) |
| HA hot-hot | ~$1,215/mo | $1,380/mo (€1,212) |
| HA multiplier | ≈ 2.8× | ≈ 2.9× |
| Unlimited scale (min) | ~$2,250/mo | $2,693/mo (€2,363) |

Azure runs **roughly 10–20% higher** than the AWS list figures at the same
shape and vCPU count. Two caveats before using that as a cloud-selection
argument:

1. The AWS column is `us-east-1`; `COST_SHAPES.md` notes EU AWS regions run
   within ~±5% of it, so the like-for-like EU gap is smaller than the table
   implies.
2. The AWS column has **not** been re-verified against the AWS Price List API
   in this pass, and its Azure section understated the Flexible Server
   ZoneRedundant line (it quotes ~$260/mo for compute + storage where the
   verified figure is ~$321 for compute alone). Do not treat the AWS numbers as
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

Re-run before every procurement cycle; Azure list prices carry
`effectiveStartDate` / `effectiveEndDate` and do move.

---

## When prices change

1. Re-run the queries above for `northeurope` in both currencies and update
   the line-item tables.
2. Recompute the three shape subtotals and the single→HA multiplier.
3. Update the per-module Azure READMEs
   (`modules/{single-vm,ha-hot-hot,unlimited-scale}/azure/README.md`) — they
   currently quote East US figures.
4. Reconcile with `COST_SHAPES.md`: its Azure section is East US and is
   superseded by this file for North Europe. If the per-vCPU meter rate itself
   changes, both files and the AWS meter table change together.
5. Keep the 🚩 list honest. If a figure gets verified, move it into a subtotal
   and say where the number came from.

## Related

- [`COST_SHAPES.md`](COST_SHAPES.md) — AWS shapes, the simplified-SKU mapping, and the canonical per-vCPU meter table
- [`docs/AZURE_HA_PARITY_AUDIT.md`](docs/AZURE_HA_PARITY_AUDIT.md) — what the Azure HA topology does and does not deliver today
- [`docs/AZURE_PATCHING_AND_MIGRATION.md`](docs/AZURE_PATCHING_AND_MIGRATION.md) — Azure rolling-patch runbook
- [`ARCHITECTURE.md`](ARCHITECTURE.md) — per-tier diagrams
