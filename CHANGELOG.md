# Changelog

All notable changes to this project are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows [SemVer](https://semver.org/).

## [Unreleased]

### Changed — BREAKING

- **Application-node sizing defaults raised to the 8-vCore training floor, and constrained to a portable ladder.** All six tier modules and all twelve product wrappers previously defaulted to 2 vCPU (`t3.large` on AWS, `Standard_D2s_v5` on Azure) as a deliberately-cheap PoC "starter" shape. They now default to `m6i.2xlarge` / `Standard_D8s_v5` (8 vCore, 32 GB).

  *Why:* the old defaults shipped **below a hard engineering floor**. Per `hailbytes-sat/docs/VM_SCALING.md`, any instance serving training content or running the recurring automations needs 8 vCores — learner video/SCORM streams off local disk through the phish server, certificate PDFs render on the same box, and a one-minute worker tick sweeps recurring campaigns, certificate expiry, risk recomputation and remedial assignment, all contending with the co-located Postgres. Below 8 those workloads starve each other and the automation sweep slips its tick, which the customer sees as reminders arriving late. The floor is enforced per-instance in product code (`controllers/api/sizing.go`, `trainingVCoreFloor = 8`), and training ships with the phish server, so it is the default workload rather than an add-on. The old defaults also matched no purchasable SKU: the marketplace floor is 8 vCPU, so the largest thing this repo deployed by default (6 metered vCores) was smaller than the smallest thing a customer could buy. See [`docs/SKU_DEPLOYMENT_MATRIX.md`](docs/SKU_DEPLOYMENT_MATRIX.md).

  **Upgrade impact:** if you rely on the module defaults, the next `terraform apply` **replaces your instances** and roughly quadruples both the infrastructure bill and the metered licence (2 → 8 vCores per node). To keep existing sizing, pin `instance_type` / `vm_size` explicitly *before* upgrading — but note that a sub-8 node is supported only for phishing-simulation-only deployments.

- **`instance_type` / `vm_size` now reject off-ladder values at plan time.** New `validation` blocks constrain the HailBytes application node to the portable set — 2, 4, 8, 16, 32, 48, 64 vCores, mapped to `m6i.large`/`xlarge`/`2xlarge`/`4xlarge`/`8xlarge`/`12xlarge`/`16xlarge` and `Standard_B2s`/`D2s_v5`/`D4s_v5`/`D8s_v5`/`D16s_v5`/`D32s_v5`/`D48s_v5`/`D64s_v5`.

  *Why:* every rung is a stock general-purpose shape on **both** clouds at the same 4 GB-per-vCore ratio, so a deployment can move between clouds without changing tier. Critically, **neither Azure `Dsv5` nor AWS `m6i` has any general-purpose size between 16 and 32 vCPU**, so a 24-vCore deployment cannot be delivered as one VM *or* as a symmetric pair (2 × 12 does not exist either) — a `Standard_D24s_v5` now fails `terraform plan` with an explanation instead of being discovered at apply, or on an invoice.

  **Upgrade impact:** this is breaking for anyone passing a value outside that set — including the previous defaults `t3.large` (burstable T-family, not on the ladder) and any `m5.*` shape. Migrate to the equivalent `m6i` / `Dsv5` rung at the same vCPU count.

  Only the HailBytes application node is constrained. `db_instance_class`, `db_ec2_instance_type`, `db_vm_size` and `redis_node_type` remain free-form: they are cloud infrastructure, not HailBytes-licensed capacity, and they do not meter.

- **Auto-scaling baseline reduced from 3 nodes to 2** (`asg_min_size`, `asg_desired_capacity`, `vmss_min_count`). A fixed three-node steady state picked an arbitrary point on what is really a range of identical 8-vCore nodes. Two is the smallest baseline that survives a node loss, and it lines up with the HA pair at 16 metered vCores so the two shapes agree. `asg_max_size` / `vmss_max_count` are unchanged at 20. Combined with the size default, the autoscale baseline meters 16 vCores (2 × 8) instead of 6 (3 × 2).

### Added

- **`vm_names` and `db_vm_name` on the Azure HA tier**, so a customer's host-naming standard can govern the VM names outright. `name_prefix` sets every other resource, but the VMs are what a naming policy actually constrains, and `<prefix>-vm-1` cannot be coerced into `svc-web-P-01` through a prefix alone — the `-vm-N` suffix and the 1-based unpadded index are ours. `vm_names` takes exactly two names in zone order (element 0 → zone 1); `db_vm_name` names the self-managed Postgres VM in `db_mode = "vm"`. Both default to `null` and keep the derived names. Renaming an existing VM **replaces** it, which on a two-node pair applied in one go is a full outage — the variable description says so. Forwarded by `sat-azure-ha` and `asm-azure-ha`.

### Changed

- **The Azure preflight is now regional, and checks rather than advises.** `quickstart/preflight-azure.sh` takes `--location` (or `HB_LOCATION`, default `northeurope`) and adds three checks that were previously prose telling the operator to go and look:

  - **Marketplace image availability in that region**, printing the Active version and flagging every version scheduled for deprecation. Accepted terms and an available image are different things — terms are subscription-scoped, availability is regional — and the failure mode is a `terraform apply` that dies at the VM, after the vnet, the Key Vault and the database already exist.
  - **Availability zones for the application SKU.** The HA tier pins zones 1 and 2 and runs a ZoneRedundant Flexible Server; neither is optional and not every region has zones.
  - **Regional vCPU quota**, compared against what the tier will actually request rather than printed for the operator to compare themselves. Short quota now says how much is needed and how much is available.

  `preflight-aws.sh` gains the same needed-vs-available comparison, with the honest caveat that Service Quotas reports the limit and not current consumption, so it can only catch a limit that is too small outright.

  Every new check degrades to a readable "could not read this, here is the command" rather than failing the script — a preflight that exits 1 because the operator lacks subscription read is worse than one that says so.

  `preflight-azure.sh` is now exercised end to end as a subprocess against the mocked CLI in `quickstart/tests/cloud_prereqs_test.sh`, which it never was — only its provider arrays were compared. Nine new subprocess cases and six output assertions, including the three regional failures.

- **A stale claim removed from the preflight output.** It said that below 8 vCPUs "the product's own sizing advisory reports 'upsize' for training workloads". That behaviour changed in `hailbytes-sat`: the advisory now escalates on measured load rather than core count, so a deliberately small instance is not told to upsize while it has headroom.

### Fixed

- **The phishing surface shared the admin allow-list, so a correctly locked-down SAT deployment served nothing to its targets.** `allowed_cidrs` governed both the admin console (443 → `admin_port`) and the phishing/landing surface (80 → `phish_port`) on `ha-hot-hot/azure`, `single-vm/azure` and `single-vm/aws`. Those two surfaces have opposite audiences: the console is for operators on an office or VPN range, and the landing pages are for simulation targets, who are by definition somewhere else.

  With one list, an operator who locks the console to their egress range also locks every target out of the landing pages. The campaign still sends. The targets get a connection timeout, no open or click is recorded, and the deployment presents as a broken product rather than a firewall rule — the failure is silent on the operator's side, which is what makes it expensive.

  New `phish_allowed_cidrs` on all three tier modules and their six wrappers governs the phishing surface alone. It defaults to `null`, which inherits `allowed_cidrs` and reproduces the previous behaviour exactly, so **no existing deployment changes on the next apply**. `allow_internet_ingress` deliberately does not gate it: that flag guards the admin surface, and applying it here would silently strip the `0.0.0.0/0` a live simulation needs, re-coupling the two lists this variable exists to separate. Inert on ASM, which has no phishing surface. Regression tests in `modules/ha-hot-hot/azure/tests/feature_flags.tftest.hcl` assert the inheritance default, the independence of the two lists, and that opening the phishing surface does not widen the admin one.

  Not addressed here: `ha-hot-hot/aws` exposes no phishing surface at all — no ALB rule, no security-group rule — so SAT on the AWS HA tier serves no landing pages. That is a separate gap from this one and is not fixed by this change.


- **Every tier but `ha-hot-hot` routed traffic to a port SAT does not listen on, and `ha-hot-hot` routed ASM's to a port ASM does not listen on.** The two products bind different ports — SAT serves its admin UI on **3333** (`config.json` `listen_url`, which the image's bootstrap banner prints verbatim as `https://<ip>:3333`) plus **80** for the phishing/landing surface, while ASM runs Django on `:8000` behind a proxy container that publishes **443**. Only `ha-hot-hot` had been corrected (#85, #87), and only for SAT.

  Consequences, all of which present as an application fault rather than a network one:

  - `single-vm/aws` and `single-vm/azure` opened **only 443**, with deny-all behind it. There is no load balancer in this tier to translate 443 to 3333, so a SAT single-VM deployment answered nothing on the address its own bootstrap banner told the operator to visit, and its landing pages — the product — were unreachable on 80.
  - `unlimited-scale/aws` and `unlimited-scale/azure` hardcoded 443 on the target group, its health check, and both sides of the ALB-to-instance hop (Azure: the LB rule, its probe, and the Application Gateway backend settings). A SAT autoscale deployment health-checked a port nothing binds, so the pool stayed empty and the frontend served 503 to everything.
  - `asm-aws-ha` and `asm-azure-ha` defaulted `admin_port = 3333` — SAT's port, inherited by the ASM wrappers. The load balancer probed and forwarded to a port no ASM node binds.

  `admin_port` and `phish_port` now default to `null` in all six tier modules and are **derived from `product`**: 3333/80 for SAT, 443 for ASM. The mapping lives in one place per tier rather than as a literal in each wrapper, because a wrapper carrying its own number is a wrapper that can silently drift from the image it deploys. All twelve wrappers forward both variables. `single-vm` also gained a separate SAT-only phishing rule, mirroring `ha-hot-hot`, so the phishing surface can be revoked independently of the admin surface.

  **Upgrade impact:** for SAT this **replaces security-group rules** on AWS (changing `from_port`/`to_port` forces replacement) and updates NSG rules in place on Azure; on the autoscale tier the target-group port change **replaces the target group**, and the ALB listener is updated to point at the new one. For ASM on `single-vm` and `unlimited-scale` the derived value is 443 and the plan is a no-op. Nothing about the public frontend port changes on any tier: 443 stays 443.

  `unlimited-scale` still has **no phishing frontend at all** — no port-80 LB rule on Azure, and the AWS port-80 listener is an HTTPS redirect rather than the SAT landing surface. `phish_port` is declared there for surface parity but is not wired. SAT landing pages are not reachable through the autoscale tier; adding a frontend is a feature, not a port correction, and is tracked separately.

- **`ARCHITECTURE.md` and `SECURITY-DEFAULTS.md` described the ports the modules were supposed to open rather than the ones the products bind.** The `single-vm` diagram showed a browser reaching the VM on 443 with no load balancer in the path; the HA diagram still claimed health checks on `/health`, a path corrected to `/api/health` / `/api/ready` in #80. Both now name the real ports and probe paths per product.

- **Removed a committed merge-conflict marker from `CHANGELOG.md`.** A stray `<<<<<<< HEAD` on line 27 had no matching `=======` or `>>>>>>>` — a resolution that kept both sides and left the opening marker behind, rendering as literal text in the changelog.

- **The self-managed database node was wrongly counted as metered, over-stating the licence fee by ~$350/mo.** `COST_SHAPES.md`, `AZURE_COST_SHAPES.md`, `docs/AZURE_PATCHING_AND_MIGRATION.md`, `quickstart/README.md` and `quickstart/deploy.sh` all told customers that in `db_mode = "ec2"` / `"vm"` the database VM "runs the HailBytes image, so it carries the meter too", making that mode *cheaper infrastructure but a higher total*. It does not. `aws_instance.db_ec2` boots `data.aws_ami.ubuntu`, and `azurerm_linux_virtual_machine.db_vm` uses a `Canonical / ubuntu-24_04-lts` `source_image_reference` with **no `plan {}` block** — plain Ubuntu with apt-installed PostgreSQL 16. Only nodes running the HailBytes Marketplace image meter. The self-managed-DB shape is therefore cheaper infrastructure *and* a lower total; what it actually gives up is managed backups, PITR and automatic failover. Metered vCores for that shape drop from 6 to 4. (`docs/SKU_DEPLOYMENT_MATRIX.md` already had this right.)

- **32-vCore annual list corrected from $67,200 to $67,300, and the derivation convention with it.** Prices were computed as `round-to-nearest-$100(monthly) × 12`, which rounds *before* multiplying and so multiplies the rounding error twelvefold. It agreed with the meter up to 16 vCPU and drifted above: −$100 at 32 and 48 vCores, −$200 at 64 and 96, −$300 at 128. Annual list is now `round100(0.24 × vCores × 8760)` and monthly `round10(0.24 × vCores × 730)`, matching `hailbytes-sat/docs/VM_SCALING.md`. Restated in `COST_SHAPES.md` and `docs/SKU_DEPLOYMENT_MATRIX.md`.

- **`HB-STD` (12 vCores) and `HB-ENT` (24 vCores) withdrawn.** Neither size exists as a general-purpose shape on either cloud. `HB-STD` was previously fulfilled as 3 × `m6i.xlarge` — three 4-vCore nodes, each *below* the 8-vCore training floor — so it is withdrawn rather than re-mapped. **Neither code may be reused for a different vCore count**: a procurement system that bought `HB-ENT` as 24 vCores must not silently receive 32. `HB-ENTP` (32) is unchanged apart from its corrected price; `HB-ENTP-HA`, `HB-MSP` and `HB-MSP-L` are proposed codes pending commercial sign-off.

- **`HB-SCALE` no longer quoted at a fixed node count.** It was specified as 48 metered vCores at a 6 × 8 steady state. The autoscale shape is a range of identical 8-vCore nodes, so the meter is `8 × instance count`, quoted from the 2-node baseline upward.

- **`ARCHITECTURE.md` HA cost claim corrected from "~6× cost of single-vm" to ~2.8×**, matching `COST_SHAPES.md`. The *licence* is exactly 2× — the meter counts vCores, not machines — and the remainder is the added load balancer, Multi-AZ database and shared Redis. The failover description now distinguishes **N** (pair of the tier below the roster: meets it normally, half capacity during failover) from **N+1** (pair of the tier the roster needs: full capacity through a failover), instead of implying the surviving node always carries full load.

- **`docs/SKU_DEPLOYMENT_MATRIX.md`: the 8-vCore floor is per instance, not per deployment.** It previously stated "the 8 vCPU floor is per **deployment**, not per instance. 4 × 2 vCPU satisfies Essential." The *commercial* floor is per deployment; the *training* floor is per instance and is checked against `runtime.NumCPU()` on each node, so 4 × 2 vCPU does not satisfy it for anything serving training content.

- **CI `examples-validate` now covers the `HB-PRO-HA` / `HB-SCALE` simplified-SKU examples.** `modules/ha-hot-hot/aws/examples/hb-pro-ha` and `modules/unlimited-scale/aws/examples/hb-scale` exist on disk and are the canonical snippets `ha-hot-hot/aws/README.md`, `unlimited-scale/aws/README.md`, and `COST_SHAPES.md` point customers to for those two named catalog SKUs, but neither was ever added to the `examples-validate` matrix in `.github/workflows/ci.yml` — so a future variable/output rename could silently break the exact example these SKUs' customers are told to copy-paste, with CI staying green throughout. No drift found today; this closes the coverage gap before one occurs.

- **`ha-hot-hot/aws`: `db_mode = "ec2"` data volume now has an actual destroy guard** ([#65](https://github.com/HailBytes/hailbytes-terraform-modules/issues/65)). `aws_ebs_volume.db_data` previously set `prevent_destroy = false` — Terraform's own default, a no-op — regardless of `var.db_deletion_protection`, which only ever protected the `db_mode = "rds"` path. A `terraform destroy`, an accidental resource removal, or a forced replacement (e.g. changing `availability_zone`) would delete the self-managed Postgres data volume with no guard and no snapshot fallback (EBS has none, unlike RDS's `final_snapshot_identifier`). `prevent_destroy` is now hardcoded to `true` unconditionally — it cannot be wired to the variable since Terraform requires a literal there. `db_deletion_protection`'s description (in `ha-hot-hot/aws`, `asm-aws-ha`, `sat-aws-ha`) now states plainly that it governs the RDS path only; EC2-mode protection is separate and always on. No resource replacement for existing deployments — this only adds a destroy guard that was already assumed to exist.
- **`ha-hot-hot/azure`: HA application VMs now get an NSG** ([#51](https://github.com/HailBytes/hailbytes-terraform-modules/issues/51)). Previously, when `vm_subnet_id` differed from `lb_subnet_id`, the app VM subnet had zero inbound filtering from this module — contrary to `SECURITY-DEFAULTS.md`'s "NSGs default to deny all inbound" claim, and unlike every sibling tier (`single-vm/azure`, `unlimited-scale/azure`, `ha-hot-hot/aws`). Adds `azurerm_network_security_group.vm` (allow-443 per `allowed_cidrs` entry, mirroring the existing `lb` NSG) and associates it with `vm_subnet_id`, gated behind a new `associate_vm_subnet_nsg` variable (default `true`) for customers who already manage NSGs on that subnet. When `vm_subnet_id == lb_subnet_id` (the common case per the variable docs), no second NSG is created — a subnet can only have one associated NSG, and the existing `lb` NSG already covers it. New `vm_nsg_id` output; forwarded through `asm-azure-ha` and `sat-azure-ha`.
  **Security-posture change for existing deployments:** if you run `asm-azure-ha` or `sat-azure-ha` with `vm_subnet_id` distinct from `lb_subnet_id`, the next `apply` will associate a new NSG that filters that subnet to port 443 from `allowed_cidrs` only — traffic previously unfiltered (monitoring agents, management tooling, other intra-VNet callers on other ports) will be blocked unless it originates from `allowed_cidrs`. Review `allowed_cidrs` before upgrading, or set `associate_vm_subnet_nsg = false` to opt out and manage the NSG association yourself (the NSG resource is still created and exported via `vm_nsg_id`).
- **HA / autoscale wrappers re-export the full tier output surface.** All 8 product wrappers (`asm`/`sat` × `aws`/`azure` × `ha`/`autoscale`) were missing `post_patch_ssm_document_name` / `post_patch_run_command_name` / `post_patch_run_command_extension_name`, `redis_endpoint`, and `redis_mode` — outputs the patching runbook tells customers to read. Additive only; no resource changes.
- **`ha-hot-hot/aws`: EC2 snapshot IAM scoped to the DB data volume** (`db_mode = "ec2"` only). `ec2:CreateSnapshot` / `ec2:CreateTags` were granted on `Resource = "*"`, letting the self-managed Postgres instance snapshot any volume in the account. Now scoped to the module's data volume and `snapshot/*` ARNs with an `ec2:CreateAction` condition; `Describe*` keeps `*` (no resource-level support).
- **`ha-hot-hot/aws`: `db_backup_retention_days` description matches actual precedence.** The deprecated alias wins over `rds_backup_retention_period` when set (it always did, via `coalesce`); the description previously claimed the opposite.
- **Azure App Gateway inputs fail fast.** `ha-hot-hot/azure` and `unlimited-scale/azure` now validate via plan-time preconditions that `appgw_subnet_id` and the TLS PFX inputs are set when `enable_application_gateway = true`, instead of a cryptic apply-time provider error.
- **`unlimited-scale/azure`: VMSS waits for Postgres read replicas** (`depends_on` previously listed only the primary).
- **azurerm floor raised to `>= 4.0, < 5.0`** (all Azure modules), and the 3.x-era `enable_rbac_authorization` / storage container `resource_manager_id` usages renamed to their 4.x forms (`rbac_authorization_enabled`, container `id`). azurerm 4.x deprecates the old names and 5.x removes them; the 4.x names don't exist in 3.x, so this is a coordinated floor bump done before the first tagged release. No resource changes on apply.

- **Shared Redis is now provisioned by default in every HA / autoscale module.** Previously `ha-hot-hot/{aws,azure}` and `unlimited-scale/{aws,azure}` shipped two-or-more application instances behind a load balancer with no shared session store, which silently broke cross-instance login and the worker-lock heartbeat in production HA deployments. The new default is an ElastiCache (AWS, Multi-AZ) / Azure Cache for Redis (Standard or Premium, zone-redundant) replication group sized at the procurement-friendly tier (`cache.t4g.small` / `Standard C1`). The Azure modules reject the single-node `Basic` SKU at validation time so an unsafe SKU choice fails fast.
- **Pre-patch SSM / Run Command documents fail loud on a missing on-AMI script.** Previously the `if [ -x /opt/hailbytes/bin/ha-pre-patch-backup.sh ]; then ...; else WARN ...; fi` guard masked the case where the AMI was built before the Packer change that installs the script. Customers running an older AMI now see an explicit "rebuild the marketplace image from main" error instead of a silently no-op backup. Same change on Azure pre-patch. Applies to both `ha-hot-hot` and `unlimited-scale`.

### Testing

- **All 12 product wrapper modules now have `terraform test` coverage** ([#42](https://github.com/HailBytes/hailbytes-terraform-modules/issues/42)). Previously only the 10 tier/network modules had `.tftest.hcl` files; the wrappers — the actual public API customers instantiate — had none. Each wrapper's `tests/basic.tftest.hcl` mirrors its core module's mock-provider fixture and asserts every re-exported output is non-empty, including `redis_endpoint`, `redis_mode`, and the post-patch SSM/Run Command outputs that regressed silently in a prior release (see the "HA / autoscale wrappers re-export the full tier output surface" entry above). The `terraform-test` CI matrix now covers all 12 wrappers in addition to the 10 core modules.

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
