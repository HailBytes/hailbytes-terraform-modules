# SKU Deployment Matrix — Can Every Published SKU Be Deployed?

> **Assessment date:** 2026-08-04
> **Question asked:** is it easy to deploy each of our simplified SKUs via this repo?
> **Short answer:** **no.** Three defects, one of them shipping in every module.
>
> This document is an assessment plus a reference table. It **changes no
> Terraform** — the headline fix would force instance replacement on running
> deployments, so it needs a decision, not a drive-by commit. See §5.

---

## 1. The published menu this repo has to serve

From `hailbytes-static/hugo-site/data/pricing.toml`, the single source of truth
for published pricing. Five listed SKUs, priced at **$0.24/vCPU/hour**, with a
hard **8 vCPU purchasable floor** (`floor_vcpu = 8`).

| SKU | vCPU | Annual list | 1-yr net (−30%) | Standard shape exists? |
|---|---:|---:|---:|---|
| Essential | 8 | $16,800 | $11,760 | **Yes** — `m5.2xlarge` / `Standard_D8s_v3` |
| Standard | 12 | $25,200 | $17,640 | **No** ᵈ |
| Professional | 16 | $33,600 | $23,520 | **Yes** — `m5.4xlarge` / `Standard_D16s_v3` |
| Enterprise | 24 | $50,400 | $35,280 | **No** ᵈ |
| Enterprise Plus | 32 | $67,200 | $47,040 | **Yes** — `m5.8xlarge` / `Standard_D32s_v5` |
| Consortium | 48+ | quote | — | `m5.12xlarge` / `Standard_D48s_v5` |

ᵈ `pricing.toml` records that no standard 12- or 24-vCPU shape exists in Azure
Dsv5 or AWS m5/m6i. This assessment confirms nothing in this repo resolves that.

### How the meter actually counts

**Billable vCores = the sum of vCPUs across every instance running the HailBytes
marketplace image.** Not the size of one VM. Verified in this repo:

- `ha-hot-hot/aws/main.tf:31` — `vm_subnets = slice(var.private_subnet_ids, 0, 2)`,
  so `aws_instance.vm` has **exactly 2** app instances.
- `ha-hot-hot/azure/main.tf:36` — `vm_count = 2`, hardcoded.
- `ha-hot-hot/aws/main.tf:467` — the database EC2 instance uses
  `data.aws_ami.ubuntu[0].id`, a **stock Ubuntu AMI**. It does **not** carry the
  marketplace image, so **it does not draw the meter.** Same for Azure, where the
  database is a Flexible Server.
- `unlimited-scale/*` — `asg_desired_capacity` / `vmss_default_count` default to
  **3**, min 3, max 20.

So a 2 × 8 vCPU HA deployment bills **16 vCores** — the Professional SKU — not
Essential. Anyone sizing per-VM instead of per-envelope quotes half the true bill.

---

## 2. Finding 1 — every module defaults below the purchasable floor

**Severity: high. Affects all six tier modules and all twelve product wrappers.**

| Tier module | Sizing default | vCPU each | Instances | **Billable vCores** |
|---|---|---:|---:|---:|
| `single-vm/aws` | `t3.large` | 2 | 1 | **2** |
| `single-vm/azure` | `Standard_D2s_v5` | 2 | 1 | **2** |
| `ha-hot-hot/aws` | `t3.large` | 2 | 2 | **4** |
| `ha-hot-hot/azure` | `Standard_D2s_v5` | 2 | 2 | **4** |
| `unlimited-scale/aws` | `m6i.large` | 2 | 3 | **6** |
| `unlimited-scale/azure` | `Standard_D2s_v5` | 2 | 3 | **6** |

**Not one tier reaches 8 vCores at its defaults.** The smallest thing a customer
can buy is 8 vCPU; the largest thing this repo deploys by default is 6 vCores.

Consequences, in order of how much they cost us:

1. **The quickstart deploys a shape that matches no SKU.** `quickstart/deploy.sh`
   is linked from the repo README and from `hailbytes.com/deploy`, and prints a
   `COST IMPACT` block with "real figures". Those figures describe a 2-vCore
   deployment nobody can purchase.
2. **For ASM it is below the product's own documented minimum.**
   `hailbytes-asm/docs/HARDENING_GUIDE.md` sets a 4 vCPU minimum and names
   8 vCPU "Production (recommended)". A 2-vCPU default ships under the minimum.
3. **First-run experience is a slow instance.** The most likely first impression
   of both products is one taken at a quarter of the recommended production size.
4. **PoC-to-production is a forced replacement.** Changing `instance_type` or
   `vm_size` after the fact replaces the VM. Every customer who starts on the
   default pays a migration to reach a purchasable size.

The variable descriptions state the defaults as though deliberate — *"t3.large is
the default for ASM/SAT single-vm tier"*. They read as endorsement, not as a
placeholder, so nothing in the repo signals to a user that the default is
unbuyable.

---

## 3. Finding 2 — no SKU is nameable, and two are unreachable

**Severity: high.**

There is no SKU vocabulary anywhere in the Terraform. `grep -rl 'Essential|Professional|Enterprise|vcpu'`
over `modules/**/*.tf` returns exactly one file, and it is an example's directory
name (`ha-hot-hot/aws/examples/hb-pro-ha`). No mapping, no lookup, no doc table.

A customer who bought "Enterprise" has to independently work out that Enterprise
means 24 vCores, then that 24 vCores across 2 HA app VMs means 12 vCPU each, then
that no 12-vCPU shape exists. **Nothing in the repo helps with any of those three
steps**, and the last one has no answer.

### Reachability per SKU per tier

Shapes are per-instance; the product is the billable total.

| SKU | vCores | `single-vm` | `ha-hot-hot` (×2) | `unlimited-scale` (×N) |
|---|---:|---|---|---|
| Essential | 8 | ✅ `m5.2xlarge` / `D8s_v3` | ✅ 2 × `m6i.xlarge` / `D4s_v5` | ✅ 4 × 2 vCPU |
| **Standard** | **12** | ❌ no 12-vCPU shape | ❌ needs a 6-vCPU shape | ✅ **3 × 4 vCPU** or 6 × 2 |
| Professional | 16 | ✅ `m5.4xlarge` / `D16s_v3` | ✅ 2 × `m5.2xlarge` / `D8s_v3` | ✅ 4 × 4 vCPU |
| **Enterprise** | **24** | ❌ no 24-vCPU shape | ❌ needs a 12-vCPU shape | ✅ **3 × 8 vCPU** |
| Enterprise Plus | 32 | ✅ `m5.8xlarge` / `D32s_v5` | ✅ 2 × `m5.4xlarge` / `D16s_v3` | ✅ 4 × 8 vCPU |

**The two derived rungs are reachable on the auto-scaling tier only** — and only
by pinning min = desired = max, which forfeits the auto-scaling the tier exists
to provide. Neither is deployable on single-VM or HA at any standard shape.

That is a commercial problem, not just a docs problem: **Standard and Enterprise
are 2 of our 5 listed SKUs, and Enterprise is the rung the current CXO4 quote is
written against.** A customer buying Enterprise for a single-VM or HA deployment
cannot land on 24 vCores.

Options, for Product and Pricing to pick from:

- **(a) Retire 12 and 24 from the ladder.** Cleanest. Leaves 8/16/32, all of
  which map to real shapes on both clouds at all three tiers. `pricing.toml`
  already notes SAT's `VM_SCALING.md` recommends 32 over 24 anyway.
- **(b) Keep them, documented as auto-scaling-tier-only**, with pinned capacity.
  Requires saying so on `/pricing/`, which currently implies every rung is
  deployable in every shape.
- **(c) Sell them as capacity envelopes** — 24 vCores = 210,240 vCPU-hours/year,
  filled by whatever topology fits. Honest, matches how the meter works, and is
  what the CXO4 quote does. Needs the ladder relabelled from sizes to envelopes.

Recommend **(a)**, with **(c)** for anything negotiated.

---

## 4. Finding 3 — no validation stops an unbillable size

**Severity: medium.**

The only `validation` blocks on the tier modules' inputs are `product`
(`contains(["asm","sat"], …)`) and `allowed_cidrs` (CIDR parse). Nothing
validates `instance_type` / `vm_size` at all.

So `terraform apply` succeeds with `t3.micro` — 2 vCPU, 1 GB RAM, well under
either product's documented minimum, and matching no SKU. The customer gets a
running instance that fails on load, and a support ticket lands on us.

The 8 vCPU floor is a commercial rule the Terraform is entirely unaware of.

---

## 5. Recommended fix — and why this document does not apply it

The fix is a `plan` variable on each tier module that names the SKU and derives
the shape, replacing hand-picked instance types:

```hcl
variable "plan" {
  description = "HailBytes SKU. Sets instance size to the shape matching the purchased plan."
  type        = string
  default     = "essential"
  validation {
    condition     = contains(["essential", "professional", "enterprise_plus"], var.plan)
    error_message = "plan must be one of: essential, professional, enterprise_plus."
  }
}
```

…with a per-cloud, per-tier lookup from `plan` → shape, so `ha-hot-hot` resolves
`professional` to 2 × `m5.2xlarge` (16 vCores) while `single-vm` resolves it to
1 × `m5.4xlarge` (also 16 vCores). One name, correct billable total, every tier.
`instance_type` / `vm_size` stay as an escape hatch for non-standard shapes.

**Why it is not in this commit — this is the part that needs a decision:**

1. **It forces instance replacement.** Changing the default from `t3.large` to
   `m5.2xlarge` replaces the EC2 instance / Azure VM on the next `apply` for
   **every existing deployment that relies on the default**. On `single-vm`
   that is the whole deployment. Per `CLAUDE.md`, a change that could force
   replacement gets raised before it is written, not shipped and explained.
2. **It changes the customer's bill 4×** (2 → 8 vCores) without them editing a
   `.tfvars`. That must be an announced, versioned change with migration notes in
   `docs/PATCHING_AND_MIGRATION.md`, not a silent default bump.
3. **The SKU list depends on §3's unresolved decision.** The `contains()` above
   deliberately omits `standard` and `enterprise` — the 12 and 24 vCore rungs —
   because neither is deployable at a standard shape. Writing the enum before
   Pricing rules on option (a)/(b)/(c) bakes in a guess.
4. **Blast radius is six tier modules and twelve wrappers.** The wrappers are the
   public API; adding a variable to all of them is a minor-version event.

### Sequencing

| # | Step | Owner | Blocked by |
|---|---|---|---|
| 1 | Rule on the 12 / 24 vCore rungs — option (a), (b) or (c) | Pricing + Product | — |
| 2 | Publish this matrix in the repo README and on `/pricing/` | Docs | 1 |
| 3 | Add `plan` + validation to the six tier modules and twelve wrappers, defaulting to `essential` (8 vCores); note replacement in `PATCHING_AND_MIGRATION.md`; minor version bump | Terraform | 1 |
| 4 | Correct `quickstart/deploy.sh` `COST IMPACT` to quote real SKU prices | Terraform | 3 |
| 5 | Add a `tflint`/CI check that no default resolves below 8 billable vCores | Terraform | 3 |

Step 2 is independently useful and unblocked once step 1 lands — a customer with
this table can hand-pick the right shape today, which is the whole of "easy to
deploy" that we can deliver without a breaking change.

---

## 6. Reference — shape per SKU per tier

For hand-configuration until step 3 ships. Set `instance_type` (AWS) or
`vm_size` (Azure) to the shape below; the tier's instance count does the rest.

### AWS

| SKU | vCores | `single-vm` `instance_type` | `ha-hot-hot` `instance_type` (×2) | `unlimited-scale` `instance_type` × count |
|---|---:|---|---|---|
| Essential | 8 | `m5.2xlarge` | `m6i.xlarge` | `m6i.large` × 4 |
| Standard | 12 | — | — | `m6i.xlarge` × 3 |
| Professional | 16 | `m5.4xlarge` | `m5.2xlarge` | `m6i.xlarge` × 4 |
| Enterprise | 24 | — | — | `m5.2xlarge` × 3 |
| Enterprise Plus | 32 | `m5.8xlarge` | `m5.4xlarge` | `m5.2xlarge` × 4 |

### Azure

| SKU | vCores | `single-vm` `vm_size` | `ha-hot-hot` `vm_size` (×2) | `unlimited-scale` `vm_size` × count |
|---|---:|---|---|---|
| Essential | 8 | `Standard_D8s_v3` | `Standard_D4s_v5` | `Standard_D2s_v5` × 4 |
| Standard | 12 | — | — | `Standard_D4s_v5` × 3 |
| Professional | 16 | `Standard_D16s_v3` | `Standard_D8s_v3` | `Standard_D4s_v5` × 4 |
| Enterprise | 24 | — | — | `Standard_D8s_v3` × 3 |
| Enterprise Plus | 32 | `Standard_D32s_v5` | `Standard_D16s_v3` | `Standard_D8s_v3` × 4 |

Notes:

- `unlimited-scale` counts are `asg_desired_capacity` / `vmss_default_count`. The
  billable total tracks the **live** instance count, so an auto-scaled deployment
  bills above the table whenever it scales out. Set
  `asg_max_size` / `vmss_max_count` to bound the bill.
- Database instances are **not** billable — stock Ubuntu on AWS
  (`db_ec2_instance_type`, default `m6i.large`), Flexible Server on Azure
  (`db_vm_size`). Size them for the database; they never touch the meter.
- The 8 vCPU floor is per **deployment**, not per instance. 4 × 2 vCPU satisfies
  Essential.
- `Standard_D8s_v3` / `D16s_v3` follow `pricing.toml`'s `azure_shape` field. The
  equivalent v5 shapes are newer and generally cheaper for the same vCPU; prefer
  v5 where the region offers it.

---

## 7. What this repo already does well

So the findings above are read in proportion — the gap is SKU alignment
specifically, not module quality:

- **Marketplace billing integrity is intact.** No Dockerfiles for HailBytes
  products, no non-marketplace binary fetches, no custom-AMI paths. Deployment is
  from published marketplace images only, and `accept_marketplace_terms` is an
  explicit gate.
- **Security defaults hold at every size.** IMDSv2 required
  (`http_tokens = "required"`), EBS optimization, detailed monitoring, customer-
  managed keys, NSG/SG defaults, `checkov` + `trivy` + `tflint` in CI. None of
  this varies with the sizing problem.
- **The tier abstraction is right.** Three shared tier modules behind twelve thin
  product wrappers is the correct shape. Finding 2 is a *missing* mapping inside a
  good structure, not a structural defect — which is why the fix in §5 is
  additive.
- **The quickstart's intent is right.** Marketplace-subscription precheck,
  `terraform plan` before `APPLY`, cost-impact blocks on every billable choice.
  It needs correct numbers, not a redesign.
