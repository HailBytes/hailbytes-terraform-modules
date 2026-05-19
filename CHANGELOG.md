# Changelog

All notable changes to this project are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows [SemVer](https://semver.org/).

## [Unreleased]

### Fixed

- **Shared Redis is now provisioned by default in every HA / autoscale module.** Previously `ha-hot-hot/{aws,azure}` and `unlimited-scale/{aws,azure}` shipped two-or-more application instances behind a load balancer with no shared session store, which silently broke cross-instance login and the worker-lock heartbeat in production HA deployments. The new default is an ElastiCache (AWS, Multi-AZ) / Azure Cache for Redis (Standard or Premium, zone-redundant) replication group sized at the procurement-friendly tier (`cache.t4g.small` / `Standard C1`). The Azure modules reject the single-node `Basic` SKU at validation time so an unsafe SKU choice fails fast.
- **Pre-patch SSM / Run Command documents fail loud on a missing on-AMI script.** Previously the `if [ -x /opt/hailbytes/bin/ha-pre-patch-backup.sh ]; then ...; else WARN ...; fi` guard masked the case where the AMI was built before the Packer change that installs the script. Customers running an older AMI now see an explicit "rebuild the marketplace image from main" error instead of a silently no-op backup. Same change on Azure pre-patch. Applies to both `ha-hot-hot` and `unlimited-scale`.

### Added

- **Post-patch verifier SSM / Run Command documents** on every HA / autoscale module (AWS `aws_ssm_document.post_patch_verify`, Azure `azurerm_virtual_machine_run_command.post_patch_verify` / `azurerm_virtual_machine_scale_set_extension.post_patch_verify`). Invokes the on-AMI `/opt/hailbytes/bin/ha-post-patch-verify.sh` five-probe verifier so a rolling-replace can fail fast on a schema-version regression, encryption-key fingerprint mismatch, or worker-lock outage.
- **`COST_SHAPES.md`** at the repo root: single source of truth for the three deployment shapes (`single` / `ha-hot-hot` / `unlimited-scale`) on both AWS and Azure, with per-vCore meter as a first-class line and procurement-grade all-in totals. Anchors module READMEs to a single canonical price reference and an Azure-Cache-for-Redis sizing table.
- **Per-product wrapper modules now expose the full Redis surface** (`enable_managed_redis`, `redis_node_type` / `redis_sku_name`, `redis_endpoint_override`, etc.) plus `enable_post_patch_run_command` on Azure. Customers using `sat-aws-ha` / `asm-aws-ha` / etc. can override every variable the core module accepts.
- **CI suite** (`.github/workflows/ci.yml`): `terraform fmt -check`, `terraform validate` (22-module matrix), `tflint --recursive`, **`tfsec`** (HIGH/CRITICAL gate + SARIF upload to code-scanning), **examples validation** (matrix across `modules/*/{aws,azure}/examples/basic`), **marketplace-id consistency** (asserts every `marketplace_product_codes` use carries the canonical AWS AMI codes + Azure publisher/offer slugs), **wrapper variable forwarding** (diffs every wrapper's `variables.tf` against its core module — would have caught the Redis-vars-not-forwarded gap above), **versions.tf existence + `required_version` pin** check, and **`COST_SHAPES.md` sync** check.

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
