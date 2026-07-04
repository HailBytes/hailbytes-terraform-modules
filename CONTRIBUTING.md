# Contributing to hailbytes-terraform-modules

Welcome. This repository ships the Terraform modules customers use to
deploy HailBytes ASM and SAT into their own AWS / Azure tenants from
the marketplace. The modules are MPL-2.0 and we accept community PRs,
with a few conventions worth knowing before you open one.

## Where the boundaries are

- **HCL only.** No bundled binaries, no `external` data sources that
  shell out to non-marketplace tooling, no `user_data` that pulls
  HailBytes software from anywhere other than the marketplace AMI /
  Azure image. See `BILLING.md` for why this is structural rather
  than stylistic.
- **One module = one tier.** `single-vm`, `ha-hot-hot`, and
  `unlimited-scale` are the three tiers. The per-product wrappers
  (`sat-aws-ha`, `asm-aws-ha`, etc.) are thin shims that hardcode
  `product` and forward every other variable. If you add a knob to a
  core module, you must forward it through both product wrappers in
  the same PR — the `wrapper-forwarding` CI gate enforces this.
- **Cost shapes have a canonical source.** All procurement-grade
  pricing flows through [`COST_SHAPES.md`](COST_SHAPES.md), which
  references `hailbytes-sat/docs/AWS_HA_DEPLOYMENT.md` for AWS list
  prices. Per-module READMEs may show their starter-default sizing
  but should link to `COST_SHAPES.md` for the cross-tier comparison.

## CI gates a PR will hit

`.github/workflows/ci.yml` runs:

1. **`terraform fmt -check`** — recursive across the tree.
2. **`terraform validate`** — per-module matrix across all 22 dirs.
3. **`tflint`** — recursive, with `terraform` + `aws` + `azurerm`
   plugins. Error severity gates the build; warnings surface in
   logs.
4. **`checkov`** (`.github/workflows/checkov.yml`) — findings fail the
   build unless waived in `.checkov.yaml`. New suppressions must add a
   `skip-check` entry with the `CKV_*` ID, a category letter, and a
   one-line rationale; PRs that suppress a finding without one are
   rejected at review.
5. **`trivy-iac`** (`.github/workflows/trivy-iac.yml`) — MEDIUM+
   misconfigurations fail the build unless waived in `.trivyignore`.
   New suppressions must add an entry with the `AVD-*` ID and a
   one-line rationale, cross-referencing the matching `.checkov.yaml`
   rule where one exists.
6. **`examples-validate`** — every `modules/*/{aws,azure}/examples/basic`
   subtree must `terraform validate` clean. Customer copy-paste
   starting points stay buildable.
7. **`marketplace-id-consistency`** — every `marketplace_product_codes`
   use carries the canonical AWS AMI codes
   (`d19hjbz3gakqdlonlf8twdmll` for SAT,
   `1n57wg1f6735e30vj5fn420bp` for ASM) and the canonical Azure
   publisher / offer slugs. See **Cross-repo marketplace verification**
   below.
8. **`wrapper-forwarding`** — every wrapper module declares the same
   variables as its core module, minus the intentionally-hidden
   `product`.
9. **`versions-tf`** — every module dir with `.tf` files has a
   `versions.tf` declaring `required_version` + `required_providers`.
10. **`cost-shapes-sync`** — `COST_SHAPES.md` carries every canonical
    marker (per-tier × per-cloud, per-vCore meter, Azure Cache
    sizing). Fails fast on a partial edit that drops a section.

## Cross-repo marketplace verification (release-time)

The CI gate in (6) above asserts that all modules in **this** repo
use the same AMI product codes and Azure publisher slugs. At release
time, an additional manual check confirms those identifiers still
match the application repos' `MARKETPLACE.md` files:

- `hailbytes-sat/MARKETPLACE.md`
- `hailbytes-asm/MARKETPLACE.md`

A drift between the application repo's `MARKETPLACE.md` and this
repo's wired-in defaults means a customer who picks a fresh tag will
deploy from the wrong image. Reconcile via the application repo
first, then mirror in this repo.

## Adding a new tier or wrapper

1. Add the core module under `modules/<new-tier>/{aws,azure}`. The
   `tier` directory should contain `main.tf`, `variables.tf`,
   `outputs.tf`, `versions.tf`, `README.md`, and `examples/basic/`.
2. Add a per-product wrapper under `modules/{sat,asm}-{aws,azure}-<new-tier>/`.
   The wrapper hardcodes `product` and forwards every other variable.
3. Extend the CI matrices in `.github/workflows/ci.yml`:
   `validate` (always), `examples-validate` (if you add an example),
   `wrapper-forwarding` (for the new wrapper-core pair).
4. Add a row to `COST_SHAPES.md` if the new tier has a meaningfully
   different cost shape.

## Adding a knob to an existing module

1. Declare the variable in the core module's `variables.tf` with a
   description, type, and a safe default.
2. Wire it through the core module's `main.tf`.
3. Add the same variable to **both** product wrappers' `variables.tf`
   and forward it in their `main.tf`. The `wrapper-forwarding` CI
   gate enforces this; if you miss a wrapper, the build fails with
   the missing var name in the error message.
4. If the new knob materially changes the cost shape, update the
   per-module README cost table AND `COST_SHAPES.md`.

## Migration notes for behaviour-changing PRs

Any PR that changes module behaviour in a way that produces a
non-empty plan diff for existing customers — adds a default-on
resource, renames a resource (`moved` block required), changes a
default that affects RDS / KMS — must include a "Migration notes"
section in `CHANGELOG.md` documenting the expected plan diff. The
Redis-by-default change in the most recent `[Unreleased]` section is
a reference example.

## License

By submitting a PR you agree your contribution is licensed under
MPL-2.0. See `LICENSE`.
