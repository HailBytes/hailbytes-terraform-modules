# Changelog

All notable changes to this project are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows [SemVer](https://semver.org/).

## [Unreleased]

### Fixed

- **HA / autoscale wrappers re-export the full tier output surface.** All 8 product wrappers (`asm`/`sat` × `aws`/`azure` × `ha`/`autoscale`) were missing `post_patch_ssm_document_name` / `post_patch_run_command_name` / `post_patch_run_command_extension_name`, `redis_endpoint`, and `redis_mode` — outputs the patching runbook tells customers to read. Additive only; no resource changes.
- **`ha-hot-hot/aws`: EC2 snapshot IAM scoped to the DB data volume** (`db_mode = "ec2"` only). `ec2:CreateSnapshot` / `ec2:CreateTags` were granted on `Resource = "*"`, letting the self-managed Postgres instance snapshot any volume in the account. Now scoped to the module's data volume and `snapshot/*` ARNs with an `ec2:CreateAction` condition; `Describe*` keeps `*` (no resource-level support).
- **`ha-hot-hot/aws`: `db_backup_retention_days` description matches actual precedence.** The deprecated alias wins over `rds_backup_retention_period` when set (it always did, via `coalesce`); the description previously claimed the opposite.
- **Azure App Gateway inputs fail fast.** `ha-hot-hot/azure` and `unlimited-scale/azure` now validate via plan-time preconditions that `appgw_subnet_id` and the TLS PFX inputs are set when `enable_application_gateway = true`, instead of a cryptic apply-time provider error.
- **`unlimited-scale/azure`: VMSS waits for Postgres read replicas** (`depends_on` previously listed only the primary).
- **azurerm floor raised to `>= 4.0, < 5.0`** (all Azure modules), and the 3.x-era `enable_rbac_authorization` / storage container `resource_manager_id` usages renamed to their 4.x forms (`rbac_authorization_enabled`, container `id`). azurerm 4.x deprecates the old names and 5.x removes them; the 4.x names don't exist in 3.x, so this is a coordinated floor bump done before the first tagged release. No resource changes on apply.

- **Shared Redis is now provisioned by default in every HA / autoscale module.** Previously `ha-hot-hot/{aws,azure}` and `unlimited-scale/{aws,azure}` shipped two-or-more application instances behind a load balancer with no shared session store, which silently broke cross-instance login and the worker-lock heartbeat in production HA deployments. The new default is an ElastiCache (AWS, Multi-AZ) / Azure Cache for Redis (Standard or Premium, zone-redundant) replication group sized at the procurement-friendly tier (`cache.t4g.small` / `Standard C1`). The Azure modules reject the single-node `Basic` SKU at validation time so an unsafe SKU choice fails fast.
- **Pre-patch SSM / Run Command documents fail loud on a missing on-AMI script.** Previously the `if [ -x /opt/hailbytes/bin/ha-pre-patch-backup.sh ]; then ...; else WARN ...; fi` guard masked the case where the AMI was built before the Packer change that installs the script. Customers running an older AMI now see an explicit "rebuild the marketplace image from main" error instead of a silently no-op backup. Same change on Azure pre-patch. Applies to both `ha-hot-hot` and `unlimited-scale`.

### Documentation

- `docs/PATCHING_AND_MIGRATION.md` referenced a nonexistent `v1.1.0` tag; now `v1.0.0` like every other doc. **A `v1.0.0` git tag must be cut on `main` before customers can use any README quickstart** — every snippet pins `?ref=v1.0.0`.
- **README and `docs/PATCHING_AND_MIGRATION.md` now call out that no `v1.0.0` tag exists yet** ([#48](https://github.com/HailBytes/hailbytes-terraform-modules/issues/48)), so a customer copy-pasting a quickstart snippet sees a pin-to-commit-SHA workaround instead of a bare `terraform init` failure. Superseded by cutting the actual tag.
- HA / autoscale READMEs now say to edit `terraform.tfvars` (replacing the `REPLACE` placeholders) before `terraform apply`.
- `COST_SHAPES.md` labels the comparison table as procurement-grade sizing, not module defaults.
- **Azure HA / autoscale: TLS termination tradeoff called out in READMEs.** In the default Standard LB mode the frontend is TCP passthrough on 443, so the browser terminates against the VM's self-signed certificate — and the certificate CN (now the per-VM IMDS hostname after the corresponding `hailbytes-asm` / `hailbytes-sat` `setup.sh` change) does not match the LB public IP nor any DNS record customers point at it. Production deployments should set `enable_application_gateway = true` with a real PFX, or front the module with their own upstream L7 LB. No code change; this documents an existing behavior that was previously silent.

### Added

- **`ha-hot-hot/azure`: customer-managed-key disk encryption** (`enable_customer_managed_key`, default `false`, exposed on `asm-azure-ha` / `sat-azure-ha`). Creates an RSA-4096 key in the module's Key Vault plus a disk encryption set covering app VM OS/data disks and the self-managed Postgres VM's OS/data disks — closing the gap with the single-vm and unlimited-scale tiers.
- **Post-patch verifier SSM / Run Command documents** on every HA / autoscale module (AWS `aws_ssm_document.post_patch_verify`, Azure `azurerm_virtual_machine_run_command.post_patch_verify` / `azurerm_virtual_machine_scale_set_extension.post_patch_verify`). Invokes the on-AMI `/opt/hailbytes/bin/ha-post-patch-verify.sh` five-probe verifier so a rolling-replace can fail fast on a schema-version regression, encryption-key fingerprint mismatch, or worker-lock outage.
- **`COST_SHAPES.md`** at the repo root: single source of truth for the three deployment shapes (`single` / `ha-hot-hot` / `unlimited-scale`) on both AWS and Azure, with per-vCore meter as a first-class line and procurement-grade all-in totals. Anchors module READMEs to a single canonical price reference and an Azure-Cache-for-Redis sizing table.
- **Per-product wrapper modules now expose the full Redis surface** (`enable_managed_redis`, `redis_node_type` / `redis_sku_name`, `redis_endpoint_override`, etc.) plus `enable_post_patch_run_command` on Azure. Customers using `sat-aws-ha` / `asm-aws-ha` / etc. can override every variable the core module accepts.
- **CI suite** (`.github/workflows/ci.yml`, plus the standalone `checkov.yml` / `trivy-iac.yml` workflows): `terraform fmt -check`, `terraform validate` (22-module matrix), `tflint --recursive`, **`checkov`** (findings fail unless waived in `.checkov.yaml`) and **`trivy-iac`** (MEDIUM+ findings fail unless waived in `.trivyignore`) with SARIF upload to code-scanning, **examples validation** (matrix across `modules/*/{aws,azure}/examples/basic`), **marketplace-id consistency** (asserts every `marketplace_product_codes` use carries the canonical AWS AMI codes + Azure publisher/offer slugs), **wrapper variable forwarding** (diffs every wrapper's `variables.tf` against its core module — would have caught the Redis-vars-not-forwarded gap above), **versions.tf existence + `required_version` pin** check, and **`COST_SHAPES.md` sync** check.

### Migration notes (existing customers)

The next `terraform apply` against an upgraded module **will provision a managed Redis replication group** unless you set `enable_managed_redis = false` and supply `redis_endpoint_override`. This is the intended behaviour — a customer-visible deployment whose two SAT/ASM instances were not sharing session state was not actually highly-available, regardless of what the LB topology suggested. Expected plan output:

- **AWS HA / autoscale**: `+ aws_elasticache_replication_group.main`, `+ aws_elasticache_subnet_group.main`, `+ aws_security_group.redis`, `+ aws_vpc_security_group_ingress_rule.redis_from_vm`. Cost impact ≈ +$50/mo at the `cache.t4g.small` default.
- **Azure HA / autoscale**: `+ azurerm_redis_cache.main`. Cost impact ≈ +$55/mo at the `Standard C1` default.

VMs will be **replaced** on apply because `user_data` / `custom_data` now carries `redis_host` / `redis_port` / `redis_tls`. Schedule the apply during a maintenance window. RDS / Postgres / data volumes are untouched.

To preserve the previous behaviour (NOT recommended — silently breaks cross-instance sessions on HA), set `enable_managed_redis = false` and provide `redis_endpoint_override` to wire an existing customer-managed Redis. The HA module emits `redis_mode = "disabled"` when neither managed Redis nor an override is configured — a loud signal in `terraform output` that the deployment is not session-safe.

After applying, **rebuild the marketplace AMIs** from the corresponding application repos (`hailbytes-sat`, `hailbytes-asm`) on the same branch that ships the Packer change which installs `/opt/hailbytes/bin/ha-pre-patch-backup.sh` and `ha-post-patch-verify.sh`. The new pre-patch SSM doc fails loud on a stale AMI rather than silently no-op-ing the backup.

## [Unreleased — prior]

### Added
- Initial repository scaffold
- `modules/single-vm/{aws,azure}` — single marketplace VM deployment
- `modules/ha-hot-hot/{aws,azure}` — active/active behind LB with managed Postgres
- `modules/unlimited-scale/{aws,azure}` — ASG/VMSS with read replicas and full observability
- `modules/network/{aws,azure}` — optional bundled landing zone (VPC/vnet + tiered subnets + NAT/private DNS); salvaged scaffolding from the deprecated byoc-security-architecture-templates repo
- Real marketplace identifiers wired as defaults:
  - AWS product codes: `1n57wg1f6735e30vj5fn420bp` (ASM) and `d19hjbz3gakqdlonlf8twdmll` (SAT); AMI lookup filters on product-code by default
  - Azure: publisher `lcmcon1687976613543`, offers `hardened_ubuntu_with_rengine` (ASM) and `gophish-phishing-simulator` (SAT), SKU `standard-v2`
- Optional `marketplace_product_code` variable on AWS modules for per-deploy overrides
- Optional `marketplace_sku_override` and `marketplace_image_version` variables on Azure modules
- HTTP→HTTPS 301 redirect listener on `ha-hot-hot/aws` and `unlimited-scale/aws` ALBs (default-on, `enable_http_redirect`)
- Postgres slow-query logging (`log_min_duration_statement=1000`) on RDS parameter groups
- Product-first wrapper modules (the public API): `asm-aws-{single,ha,autoscale}`, `asm-azure-{single,ha,autoscale}`, `sat-aws-{single,ha,autoscale}`, `sat-azure-{single,ha,autoscale}` — 12 thin wrappers around the 6 internal tier modules with `product` hardcoded
- SAT auto-scaling tiers (`sat-aws-autoscale`, `sat-azure-autoscale`) for large-population training campaigns and bursty report generation
- Azure auto-scaling for ASM (`asm-azure-autoscale`) — parity with the AWS side
- Top-level docs: README, ARCHITECTURE, BILLING, SECURITY (responsible disclosure), SECURITY-DEFAULTS (module-level posture)
- CI: `terraform validate`, `tflint`, `checkov`, `trivy` IaC scan — matrices expanded to cover all 20 modules
- MPL-2.0 license
