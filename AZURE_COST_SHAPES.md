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
