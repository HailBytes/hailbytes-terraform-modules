# HailBytes Terraform Modules

Terraform modules for deploying HailBytes ASM and HailBytes SAT on AWS and Azure. The modules are free/MPL-2.0; the VM images they deploy are commercial software billed through AWS or Azure Marketplace.

## Coding Approach

**Think first.** State assumptions before implementing. Terraform changes that affect running deployments can be destructive — if a change could force resource replacement (especially databases, instances, or security groups), say so explicitly before touching the code. If the blast radius is unclear, stop and ask.

**Simplicity first.** Minimum HCL that solves the problem. No new variables, outputs, or resources beyond what the task requires. No "future-proofing" that adds complexity today.

**Surgical changes.** The shared tier modules (`single-vm/`, `ha-hot-hot/`, `unlimited-scale/`) underlie two products each. A change there affects all six product-prefixed wrappers. Be explicit about scope. Don't reformat `.tf` files that aren't part of the change.

**Verify before done.** Run `terraform validate` and `tflint` locally before pushing. All PRs must pass `terraform validate`, `tflint`, `checkov`, and `trivy`. State a brief plan with these checks for multi-step work.

## Hard Rules (non-negotiable)

- **Never bypass marketplace billing.** No Dockerfiles or container manifests for HailBytes products. No `user_data`/cloud-init that downloads HailBytes binaries from a non-marketplace source. No modules that deploy from custom-built AMIs/VHDs. Contributions doing this are closed without merge.
  - **One reviewed exception:** `source_image_id` on the Azure HA tier module and its SAT wrapper, for validating image-side fixes before marketplace publication. Null by default; accepts only a Compute Gallery image *version* id; and when set it drops the `plan` block so the deployment is **not** marketplace-metered and cannot be sold from. See [docs/DEPLOY_FROM_GALLERY.md](docs/DEPLOY_FROM_GALLERY.md). A non-null value outside CI is a defect. This exception does not license any further bypass.
- Modules deploy exclusively from published HailBytes Marketplace images.
- Checkov findings not waived in `.checkov.yaml` are CI failures. Fix them; don't suppress new ones without justification.
- Don't remove or weaken security defaults (encryption, IMDSv2, IAM least-privilege, NSG defaults). If a task seems to require it, raise it explicitly.

## Module Structure

Product-prefixed modules (e.g. `asm-aws-ha`) are **thin wrappers** around shared tier modules with `product` hardcoded. The product-prefixed names are the **public API**.

| Tier module (implementation) | Product wrappers |
|------------------------------|------------------|
| `modules/single-vm/aws` | `asm-aws-single`, `sat-aws-single` |
| `modules/single-vm/azure` | `asm-azure-single`, `sat-azure-single` |
| `modules/ha-hot-hot/aws` | `asm-aws-ha`, `sat-aws-ha` |
| `modules/ha-hot-hot/azure` | `asm-azure-ha`, `sat-azure-ha` |
| `modules/unlimited-scale/aws` | `asm-aws-autoscale`, `sat-aws-autoscale` |
| `modules/unlimited-scale/azure` | `asm-azure-autoscale`, `sat-azure-autoscale` |

Changes to a tier module automatically affect both products that use it.

## CI / Linting

Every PR runs:
- `terraform validate` — syntax and schema
- `tflint` (config: `.tflint.hcl`) — Terraform best-practice lints
- `checkov` (config: `.checkov.yaml`) — security policy
- `trivy` — vulnerability scanning

Run `terraform validate` and `tflint` locally before pushing.

## Provider / Terraform Requirements

| Tool | Minimum |
|------|---------|
| Terraform | `>= 1.5.0` |
| AWS provider | `>= 5.0` |
| Azure provider | `>= 4.0, < 5.0` |

GovCloud (AWS) and Azure Government are out of scope for v1.

## Key Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md) — per-tier diagrams, shared responsibility model
- [BILLING.md](BILLING.md) — marketplace billing model, why no containers
- [COST_SHAPES.md](COST_SHAPES.md) — three deployment shapes side-by-side with pricing (AWS-first)
- [AZURE_COST_SHAPES.md](AZURE_COST_SHAPES.md) — Azure/North Europe pricing in EUR + USD, verified against the Azure Retail Prices API
- [SECURITY-DEFAULTS.md](SECURITY-DEFAULTS.md) — security controls baked into all modules
- [docs/PATCHING_AND_MIGRATION.md](docs/PATCHING_AND_MIGRATION.md) — pre-patch backups, rolling-replace, auto-rollback (AWS)
- [docs/AZURE_PATCHING_AND_MIGRATION.md](docs/AZURE_PATCHING_AND_MIGRATION.md) — the Azure procedure, incl. Postgres advisory-lock migration serialisation
- [docs/DEPLOY_FROM_GALLERY.md](docs/DEPLOY_FROM_GALLERY.md) — test-only: booting a self-built Compute Gallery image, and why such a deployment is not marketplace-metered
- [docs/AZURE_HA_PARITY_AUDIT.md](docs/AZURE_HA_PARITY_AUDIT.md) — Azure-vs-AWS HA gap table with effort estimates
- [docs/MARKETPLACE_IMAGE_ACCESS_AUDIT.md](docs/MARKETPLACE_IMAGE_ACCESS_AUDIT.md) — no-retained-access claims, verified per claim
- [docs/SKU_DEPLOYMENT_MATRIX.md](docs/SKU_DEPLOYMENT_MATRIX.md) — which published SKU each tier can actually deploy, per-cloud shape table, and the three gaps between the price ladder and the module defaults
- [CONTRIBUTING.md](CONTRIBUTING.md) — PR requirements and contribution rules
- [CHANGELOG.md](CHANGELOG.md) — release history
