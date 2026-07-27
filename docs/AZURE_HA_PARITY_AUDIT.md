# Azure HA parity audit — `ha-hot-hot/azure` vs `ha-hot-hot/aws`

**Audited:** 2026-07-26, at `ad4b352` (`main`).
**Updated:** 2026-07-26 — **A1, A2, A3, A4 and A7 are fixed** on
`claude/azure-ha-parity-audit-2pv5iv`; rows below are marked ✅ FIXED with what
changed. The verdict section still describes the state at audit time, with the
current state called out underneath.
**Question:** can we deliver a zone-redundant HailBytes SAT deployment on Azure
today, at parity with the AWS multi-AZ topology (ALB + 2× EC2 across AZs +
ElastiCache Redis Multi-AZ + RDS Postgres Multi-AZ)?
**Target region:** North Europe (`northeurope`, Dublin).
**Method:** static read of every `.tf` file in `modules/*/azure` and
`modules/*/aws`, the `.tftest.hcl` suites, `.github/workflows/ci.yml`, and the
HA patch scripts in `hailbytes-sat` / `hailbytes-asm`. No `terraform apply`
against a live subscription was performed — see
[What this audit could not test](#what-this-audit-could-not-test).

---

## Verdict

**No — not today, and not with a configuration change alone.**

The Azure HA topology is **structurally complete and materially more built out
than a stub**: 1,036 lines of HCL, two zonal VMs, a Standard Load Balancer with
a health probe, a Zone-Redundant PostgreSQL Flexible Server, an Azure Cache for
Redis, Key Vault with a generated DB password, an optional CMK disk-encryption
set, an immutable backup container, patch Run Commands, Azure Monitor
tripwires, NSGs on both subnets, an optional Application Gateway with WAF hook,
`terraform validate` + `terraform test` + `tflint` + `checkov` + `trivy` in CI,
and full wrapper-forwarding enforcement. Somebody built this properly.

But **four defects in the data path mean a fresh `terraform apply` produces a
deployment that cannot function**, and they are code defects, not tuning:

1. The app VMs' managed identities are never granted read access to the Key
   Vault holding the database password.
2. The Redis cache is provisioned with its public endpoint disabled and no
   private endpoint, on a SKU that cannot be VNet-injected — it is unreachable
   from the VMs by construction.
3. No Redis credential is ever passed to the VMs.
4. Nothing in any Azure module provisions an outbound egress path, so the VMs
   cannot reach the internet at all.

Any one of those is a hard stop. Individually they are small fixes; together
they mean **nobody has ever run this module end-to-end against a live
subscription.** The AWS HA module, by contrast, wires all four of these
(`aws_iam_role_policy.secrets`, ElastiCache in a VPC subnet group, the same
missing-auth-token gap but on a service that permits it, and
`aws_nat_gateway` per AZ in `modules/network/aws`).

> **Update — all four are now fixed**, along with A7 (the post-patch verifier,
> which was broken on AWS too). The app VMs get a `Key Vault Secrets User`
> assignment; the cache gets a private endpoint plus a private DNS zone and its
> access key lands in Key Vault; `modules/network/azure` gets a NAT Gateway
> behind `enable_nat_gateway` (default `true`, matching AWS). `terraform fmt`,
> `validate` across all 20 CI modules, both wrapper-forwarding checks and the
> `terraform test` suites pass locally. **They have still not been applied
> against a live subscription** — that remains the gating step, and it is where
> A6 and C1 will be settled.

**Estimated effort to a demonstrable zone-redundant Azure SAT deployment in
North Europe: 8–12 engineer-days**, of which ~4 are the P0 code fixes, ~3 are a
live end-to-end validation in a real subscription (the step that has never
happened), and ~3 are the TLS-termination decision, which is a product call as
much as an engineering one. Add 4–6 days for the P1 items that a security
reviewer on a 600k-learner deal will ask about (flow logs, access logs,
break-glass access, CMK coverage on the managed services).

---

## AWS → Azure component map

| AWS component | Azure equivalent in the module | Real? | Notes |
|---|---|---|---|
| **ALB** (L7, HTTPS listener, ACM cert, `lb_cookie` stickiness, HTTP→HTTPS redirect, `drop_invalid_header_fields`, access logs) | `azurerm_lb` **Standard SKU, L4** + `azurerm_lb_rule` TCP 443 passthrough + `azurerm_lb_probe` HTTPS `/health` | ⚠️ **partial** | Not an L7 equivalent. No TLS termination, no certificate input, no HTTP→HTTPS redirect, no stickiness setting, no access logging. Operators' browsers hit the VM's self-signed cert, whose CN never matches the LB IP. |
| ALB + optional `aws_wafv2_web_acl_association` | `azurerm_application_gateway` (`enable_application_gateway = true`) + `firewall_policy_id` | ⚠️ **opt-in, unvalidated** | This *is* the real L7/WAF/TLS answer, but it is off by default, requires a PFX and a dedicated `/24` subnet the `network/azure` module does not create, and its backend-HTTPS-to-self-signed-cert config is likely to fail health probes (see gap A6). |
| **2× EC2 across AZs** (`aws_instance`, one per private subnet, IMDSv2 required, encrypted gp3 root + data volume) | `azurerm_linux_virtual_machine` ×2, `zone = ["1","2"]`, Premium_LRS OS + data disk, system-assigned identity | ✅ **real** | Genuine zonal spread. Zones 1/2 exist in North Europe. Premium_LRS is zone-local, which is correct for a per-VM disk. |
| EC2 instance profile → `secretsmanager:GetSecretValue` on the DB secret | *(nothing)* | ⛔ **missing** | Gap A1. The single most consequential omission in the module. |
| IMDSv2 required (`http_tokens = "required"`) | Azure IMDS requires the `Metadata: true` header by design | ✅ **real** | Platform-equivalent; no knob needed. |
| **ElastiCache Redis Multi-AZ** (`aws_elasticache_replication_group`, 2 nodes, `automatic_failover_enabled`, `multi_az_enabled`, in-VPC via subnet group, at-rest + transit encryption) | `azurerm_redis_cache`, Standard C1, `non_ssl_port_enabled = false`, `minimum_tls_version = "1.2"`, `public_network_access_enabled = false` | ⛔ **provisioned but unreachable** | Gaps A2 + A3. Also **not zone-redundant** on the default Standard SKU — `zones` is only set when `redis_sku_name = "Premium"`, and Azure offers zone redundancy for this service on Premium and above only. The README's "Standard C1, zone-redundant primary/replica" is wrong. |
| **RDS Postgres Multi-AZ** (`multi_az = true`, `rds.force_ssl`, automated backups, deletion protection, final snapshot, PITR, encrypted, optional CMK, Performance Insights, enhanced monitoring, CloudWatch log exports) | `azurerm_postgresql_flexible_server`, `high_availability { mode = "ZoneRedundant" }`, `require_secure_transport = ON`, `backup_retention_days = 14`, VNet-integrated via delegated subnet + private DNS zone | ✅ **real** (with two caveats) | The strongest part of the Azure module and a genuine peer to RDS Multi-AZ. Caveats: no CMK support (AWS applies its KMS key to RDS storage), and no observability knobs equivalent to Performance Insights / enhanced monitoring / log exports. Also no `deletion_protection` equivalent. |
| Secrets Manager + `random_password` + optional KMS | Key Vault (RBAC-authorized, purge protection, 30-day soft delete) + `random_password` + `azurerm_key_vault_secret` with `content_type` and expiry | ✅ **real** | Better hygiene than the AWS side in places (secret content-type, rotation-deadline metadata). Undermined entirely by A1. |
| KMS CMK across EBS, RDS, Secrets Manager, SNS, S3, CloudWatch Logs | `azurerm_disk_encryption_set` + `azurerm_key_vault_key` (RSA-4096) — **VM disks only** | ⚠️ **partial** | `enable_customer_managed_key = true` covers OS and data disks. Flexible Server, Redis and the backup Storage Account stay on platform-managed keys. |
| **NAT Gateway per AZ** (`modules/network/aws`, `enable_nat_gateway`) | *(nothing, in any Azure module)* | ⛔ **missing** | Gap A4. `modules/network/azure` creates a VNet, three subnets, NSGs and the Postgres private DNS zone — and no NAT Gateway, no LB outbound rule, no public IPs on the VMs. |
| Security groups, deny-by-default, referenced-SG rules | NSGs on the LB subnet and (since #51) the VM subnet, `allow-https-*` from `allowed_cidrs` | ✅ **real** | Azure's default rules already deny inbound from the internet and permit intra-VNet, so the posture matches. Note Azure permits one NSG per subnet, which the module handles correctly via the `vm_subnet_id != lb_subnet_id` guard. |
| **VPC Flow Logs** (`enable_flow_logs`, default `true`) | *(nothing)* | ⛔ **missing** | Gap B1. `SECURITY-DEFAULTS.md` claims "VPC Flow Logs / Azure NSG Flow Logs are enabled by default (`enable_flow_logs = true`)". The variable does not exist in any Azure module. |
| **ALB access logs → S3** (`enable_alb_access_logging`, versioned + lifecycled bucket) | *(nothing)* | ⛔ **missing** | Gap B2. No `azurerm_monitor_diagnostic_setting` anywhere in the Azure modules, and no Log Analytics workspace. `SECURITY-DEFAULTS.md` claims a Storage Account destination with a 90-day lifecycle. |
| SSM Session Manager break-glass (`enable_management_access` → `AmazonSSMManagedInstanceCore`) | *(nothing)* | ⛔ **missing** | Gap B3. `SECURITY-DEFAULTS.md` says "Modules wire these up when `enable_management_access = true`" and names Azure Bastion. No Bastion, no AAD-login extension, no such variable on Azure. |
| S3 backup bucket: versioning, Object Lock GOVERNANCE, lifecycle IA→Deep Archive, least-privilege `s3:PutObject` on a prefix | Storage Account (ZRS, Cool, TLS1.2, no shared keys, no public access) + container + unlocked immutability policy + management policy Cool→Archive + `Storage Blob Data Contributor` per VM identity | ✅ **real** | Genuine parity, arguably better (`shared_access_key_enabled = false`). The container is correct; nothing fills it (gap A5). |
| SNS topic + email subscription | `azurerm_monitor_action_group` + email receiver | ✅ **real** | |
| CloudWatch alarms: ALB 5xx **rate** (metric math), unhealthy host count | Azure Monitor metric alerts: LB `VipAvailability` < 100, App Gateway backend 5xx **count** | ⚠️ **partial** | Detection exists. The 5xx alert only exists when App Gateway is enabled, and it is a raw count (default 10 per 5 min) rather than a rate, so it needs per-deployment tuning to be meaningful. |
| SSM document `pre-patch-backup` (on-demand, `aws:runShellScript`) | `azurerm_virtual_machine_run_command` `RunPrePatchBackup` | ⛔ **non-functional** | Gap A5. Wrong env contract, and the script has no Azure Blob support. |
| SSM document `post-patch-verify` | `azurerm_virtual_machine_run_command` `RunPostPatchVerify` ×2 | ⛔ **non-functional** | Gap A7 — and the AWS document has the identical defect. |
| ASG instance refresh with `auto_rollback` (autoscale tier only) | VMSS `rolling_upgrade_policy` + `automatic_instance_repair` (autoscale tier only) | ✅ **real, other tier** | Neither HA tier has this; both rely on operator-driven replacement. Noted only to stop the comparison being read as an Azure gap. |
| `lifecycle { ignore_changes = [ami, user_data] }` on the instances | *(no `lifecycle` block on `azurerm_linux_virtual_machine.vm`)* | ⚠️ **behavioural divergence** | Gap B5. On AWS a new AMI never plans a replacement. On Azure, bumping a pinned `marketplace_image_version` plans replacement of **both** VMs, and a plain `terraform apply` executes both — a full outage where the AWS module gives you a no-op. |

---

## Gap table

Severity: **P0** blocks a working deployment · **P1** blocks a
procurement/security review or a claim we have made in writing · **P2**
polish, drift, or documentation.

Effort is engineer-days including tests and a CI-green PR, and excludes the
shared live-validation effort called out separately at the end.

| # | Gap | Sev | Evidence | Fix | Effort |
|---|---|---|---|---|---|
| **A1** | **App VMs cannot read the DB password.** No role assignment grants `azurerm_linux_virtual_machine.vm[*]`'s system-assigned identity any Key Vault data-plane role. The vault is `rbac_authorization_enabled = true`, so no access policy fallback exists either. The `custom_data` tells each VM to fetch `hailbytes-db-password` from a vault it is not authorized to read. | P0 | `modules/ha-hot-hot/azure/main.tf` — role assignments exist for the Terraform caller (`kv_secret_writer`, `kv_crypto_officer`), the disk-encryption set (`des_kv_crypto_user`), the **DB** VM in `db_mode = "vm"` (`db_vm_kv_reader`), and blob writes (`vm_backup_writer`). None for the app VMs. Compare `aws_iam_role_policy.secrets` in the AWS module. | Add `azurerm_role_assignment` "Key Vault Secrets User" scoped to the vault, `count = local.vm_count`, `principal_id = azurerm_linux_virtual_machine.vm[count.index].identity[0].principal_id`. Add it to `depends_on` for anything ordering-sensitive. | ✅ **FIXED** — `azurerm_role_assignment.vm_kv_secrets_user`, one per VM, plus a regression assertion in `tests/basic.tftest.hcl`. Effort as estimated. |
| **A2** | **Redis is unreachable by construction.** `public_network_access_enabled = false` with no `azurerm_private_endpoint` and no `subnet_id` — and VNet injection is a Premium-tier-only feature, so a Standard C1 cache *cannot* be placed in the VNet. The cache has no reachable network path from the VMs in the default configuration. | P0 | `modules/ha-hot-hot/azure/main.tf` `azurerm_redis_cache.main`. `grep -rn private_endpoint modules/` returns only the Postgres DNS zone name — there is no private endpoint anywhere in the repo. Same defect in `unlimited-scale/azure`. | Either (a) add `azurerm_private_endpoint` + `privatelink.redis.cache.windows.net` private DNS zone + VNet link (works on Standard, keeps the cost line at €88/mo), or (b) default `redis_sku_name` to `Premium` and inject into a subnet (+€267/mo, and gets real zone redundancy). **(a) is the right default; offer (b) for customers who require zone-redundant cache.** | ✅ **FIXED** — `azurerm_private_endpoint.redis` + `azurerm_private_dns_zone.redis` (created here, or supply a shared one via the new `redis_private_dns_zone_id`). Private Link works on the Standard tier, so the default SKU stays as-is. Effort as estimated. |
| **A3** | **No Redis credential reaches the VMs.** `custom_data` carries `redis_host`, `redis_port`, `redis_tls` and nothing else. Azure Cache for Redis requires an access key (or Entra auth); the module never reads `primary_access_key` and never stores it in Key Vault. | P0 | `modules/ha-hot-hot/azure/main.tf` `custom_data` block. `grep -rn primary_access_key modules/` → no matches. | Write `azurerm_redis_cache.main[0].primary_access_key` to a Key Vault secret and pass the secret name in `custom_data`. Requires a matching image-side change in SAT/ASM to read it — coordinate cross-repo. Alternatively enable Entra-based auth on the cache and grant the VM identities the Redis data-access role. | ✅ **FIXED** — the cache's `primary_access_key` is written to `azurerm_key_vault_secret.redis` and the secret *name* is passed in `custom_data`. **Requires a matching image-side change**: SAT/ASM must read `redis_secret_name` from instance metadata and fetch the key. Until that ships, the credential is in place but unused. Effort as estimated. |
| **A4** | **No outbound internet path.** Nothing in `modules/network/azure` or any workload tier creates a NAT Gateway, an LB outbound rule, or VM public IPs. VMs that are members of a Standard **public** LB's backend pool with only inbound rules get no outbound SNAT. Consequences: no OS security updates (the image enables `unattended-upgrades`), no SMTP sending — which is the entire point of SAT — and no customer-chosen integrations. | P0 | `modules/network/aws/main.tf` has `aws_nat_gateway` + `aws_eip` per AZ behind `enable_nat_gateway`. `grep -rniE 'nat_gateway\|outbound_rule' modules/**/azure` → nothing. | Add `azurerm_nat_gateway` + public IP + subnet association to `modules/network/azure`, gated behind `enable_nat_gateway` (default `true`, matching AWS). Cost is now verified: €28.84 / $32.85 per month base plus €0.0395 / $0.045 per GB processed — and the per-GB line applies to traffic to Azure's own services too, so add service endpoints for Storage and Key Vault at the same time to keep that traffic off it. See `AZURE_COST_SHAPES.md`. | ✅ **FIXED** — `azurerm_nat_gateway` in `modules/network/azure` behind `enable_nat_gateway` (default `true`). Single regional gateway, not per-zone: a zonal outage can take egress while the zone-spread VMs keep serving inbound. Per-zone gateways remain a follow-up. Effort as estimated. |
| **A5** | **Pre-patch backup produces nothing.** `ha-pre-patch-backup.sh` uploads only via `aws s3 cp` when `AWS_S3_BUCKET` is set, and requires `HAILBYTES_SAT_DB_HOST` / `_USER` / `_NAME` / `PGPASSWORD`. The Azure Run Command exports `AZURE_STORAGE_ACCOUNT` / `_CONTAINER` / `AZURE_BLOB_PREFIX` (never read) and none of the required four, so the script exits 1 before `pg_dump`. The immutable container is provisioned and stays empty. | P0 | `hailbytes-sat/scripts/ha-pre-patch-backup.sh` (header + line ~156); `modules/ha-hot-hot/azure/main.tf` `pre_patch_backup`. Identical AWS-only limitation in `hailbytes-asm/scripts/ha-pre-patch-backup.sh`. | Add an Azure branch to both products' scripts (`az storage blob upload --auth-mode login` when `AZURE_STORAGE_ACCOUNT` is set), and export the DB env + Key-Vault-sourced `PGPASSWORD` from the Run Command. Manual workaround documented in [`AZURE_PATCHING_AND_MIGRATION.md`](AZURE_PATCHING_AND_MIGRATION.md#step-2--pre-patch-backup). | **2** (cross-repo) |
| **A6** | **App Gateway backend HTTPS will likely 502.** `backend_http_settings` uses `protocol = "Https"` against VMs presenting a first-boot self-signed certificate, with no `trusted_root_certificate_names`. App Gateway v2 validates backend certificates. | P0 *(for the recommended production path)* | `modules/ha-hot-hot/azure/main.tf` `azurerm_application_gateway.main`. The README recommends this path for production. | Either upload the VM cert as a trusted root, or terminate at the gateway and use `protocol = "Http"` on the backend hop over the private VNet, or have the image accept an operator-supplied cert. Needs a live test to confirm the failure before choosing. | **1.5** |
| **A7** | **Post-patch verify runs no probes.** `ha-post-patch-verify.sh` requires a positional `<admin-host>`; both the Azure Run Command and the AWS SSM document invoke it with none, so it exits 1 at the usage check. Both also export `HAILBYTES_SCHEMA_VERSION_PATH` / `HAILBYTES_MIN_SCHEMA_VERSION`, which the script does not read. | P0 | `hailbytes-sat/scripts/ha-post-patch-verify.sh` lines 38–46; `modules/ha-hot-hot/azure/main.tf` `post_patch_verify`; `modules/ha-hot-hot/aws/main.tf` `aws_ssm_document.post_patch_verify`. | Pass the VM's private IP and port. Cheapest correct fix is in the module templates on both clouds; better is to have the script default to `127.0.0.1` when run on-box. **Affects AWS too — this is not an Azure-only gap.** | ✅ **FIXED on both clouds** — the verifier is now invoked as `... 127.0.0.1 <admin_port>` via the new `admin_port` variable. Effort as estimated. |
| **B1** | **No flow logs.** `enable_flow_logs` is AWS-only; `SECURITY-DEFAULTS.md` states Azure NSG flow logs are on by default. | P1 | `grep -rln enable_flow_logs modules/` → AWS modules only. | Add VNet flow logs (`azurerm_network_watcher_flow_log`) + a Storage Account destination, gated on `enable_flow_logs` for symmetry. Note NSG flow logs are being retired in favour of VNet flow logs — build the VNet variant. | **1.5** |
| **B2** | **No load-balancer or gateway access logs, and no diagnostic settings at all.** AWS ships optional ALB access logs to a versioned, lifecycled bucket. Azure ships nothing, and `SECURITY-DEFAULTS.md` claims a Storage Account with a 90-day lifecycle. | P1 | No `azurerm_monitor_diagnostic_setting` in any Azure module. | Add diagnostic settings for the LB / App Gateway (and ideally Flexible Server + Redis) to a Storage Account or Log Analytics workspace, behind one variable. | **1.5** |
| **B3** | **No break-glass management access.** No Azure Bastion, no AAD-login extension, no `enable_management_access`. SSH is the only path, and with no NAT/public IP there is no path at all until A4 lands. `SECURITY-DEFAULTS.md` promises Bastion. | P1 | `grep -rn enable_management_access modules/**/azure` → nothing. | Add `enable_management_access` on Azure: either the `AADSSHLoginForLinux` extension + role assignment, or an `azurerm_bastion_host` (needs an `AzureBastionSubnet`). Document which. | **1.5** |
| **B4** | **Redis "zone-redundant" claim is false at the default SKU.** The module comment, `modules/ha-hot-hot/azure/README.md` ("Standard C1, zone-redundant primary/replica") and `COST_SHAPES.md` all describe the default Standard tier as zone-redundant. Azure provides zone redundancy for this service on Premium and above, and the module only sets `zones` for Premium. | P1 | `azurerm_redis_cache.main`: `zones = var.redis_sku_name == "Premium" ? ["1","2"] : null`, with `redis_sku_name` defaulting to `"Standard"`. | Correct all three docs. Decide whether "zone-redundant deployment" as sold to a customer requires defaulting to Premium P1 (+€267 / +$304 per month). **This is a written-claim exposure, not just a doc nit.** | **0.5** (doc) / **1** (default change + cost sign-off) |
| **B5** | **A single `terraform apply` replaces both VMs.** No `lifecycle` block on `azurerm_linux_virtual_machine.vm`, no `create_before_destroy`. Bumping a pinned image version plans two replacements and applies both. The AWS module's `ignore_changes = [ami, user_data]` makes the same operation a no-op. | P1 | `modules/ha-hot-hot/azure/main.tf` vs `modules/ha-hot-hot/aws/main.tf` `aws_instance.vm` lifecycle. | Decide the intended semantic and make it explicit. Recommended: keep replacement visible in `plan` (it is more honest than the AWS behaviour) but add `create_before_destroy` and document the `-target` procedure — already written up in the patching runbook. | **1** |
| **B6** | **No CMK for Flexible Server, Redis, or the backup Storage Account.** `enable_customer_managed_key` covers VM disks only; the AWS module threads its KMS key through RDS, ElastiCache, Secrets Manager, SNS, S3 and CloudWatch Logs. | P1 | `grep -n customer_managed_key modules/ha-hot-hot/azure/main.tf` — disk encryption set only. | Add CMK wiring for Flexible Server (needs a user-assigned identity + `customer_managed_key` block) and the Storage Account. Redis CMK is Premium-only. | **2** |
| **B7** | **No TLS termination or HTTP→HTTPS redirect in the default topology.** The AWS module requires `acm_certificate_arn` and terminates at the ALB; the Azure default is TCP passthrough to a self-signed cert. `enable_http_redirect` has no Azure equivalent. The README is honest about this, which is why it is P1 and not P0 — but "browsers warn on every visit" is not a deliverable for a 600k-learner rollout. | P1 | `modules/ha-hot-hot/azure/README.md` § TLS termination. | Product decision: make App Gateway the default for the HA tier (raises the floor cost by ~€164–295/mo and requires a PFX input + a gateway subnet), or accept upstream-LB-required and say so in the offer. Depends on A6. | **2–3** (incl. A6) |
| **B8** | **No bring-your-own Postgres.** `db_mode` accepts only `flexible_server` or `vm`. Redis, by contrast, *can* be brought by the customer (`redis_endpoint_override` + `enable_managed_redis = false`). A customer who already operates Postgres at scale — which describes most consortium and national-scale education buyers — cannot point the module at it, and so pays Azure for a Flexible Server they do not need. | P1 | `modules/ha-hot-hot/azure/variables.tf` `db_mode` validation vs `redis_endpoint_override`. Same in `unlimited-scale/azure`. | Add `db_mode = "external"` with `db_host` / `db_port` / `db_secret_name` inputs, validated to require TLS, and skip the Flexible Server resources. Removes $3,469–38,964/yr of the customer's Azure spend depending on SKU (see [`../AZURE_COST_SHAPES.md`](../AZURE_COST_SHAPES.md#reducing-the-customers-azure-bill)) at zero revenue cost to HailBytes, since the plan price is fixed at the licensed-VM vCore count. | **2** |
| **C1** | **Private DNS zone name may be wrong for VNet integration.** `modules/network/azure` creates `privatelink.postgres.database.azure.com` — the Private *Endpoint* zone name — while the workload modules use private access via a **delegated subnet**, whose zone is conventionally `<name>.private.postgres.database.azure.com`. | P2 *(possible P0 — unverified)* | `modules/network/azure/main.tf` `azurerm_private_dns_zone.postgres`. | Verify against a live `terraform apply` in North Europe. If Azure rejects or mis-resolves it, this is a P0 and A-list item. Cheap to test, cannot be settled from static reading. | **0.5** to verify |
| **C2** | **`azurerm_virtual_machine_run_command` is not an on-demand document.** The script body executes when Terraform *creates* the resource. `PATCHING_AND_MIGRATION.md` describes both Run Commands as documents "the customer fires from the Portal", which mis-describes the resource. | P2 | `azurerm_virtual_machine_run_command` semantics; `docs/PATCHING_AND_MIGRATION.md` row 1 and step 2. | Correct the doc (done for Azure in the new runbook), and consider shipping the scripts in the image only, with a documented `az vm run-command invoke` instead of a persistent resource. | **0.5** |
| **C3** | **Tests never exercise North Europe, zone placement, or IAM wiring.** Both Azure HA test files use `location = "eastus"`. No assertion covers zone assignment, the Key Vault role assignments, Redis reachability, or `db_mode = "vm"`. `create_backup_storage_account` is forced `false` in both suites, so the backup path is untested. | P2 | `modules/ha-hot-hot/azure/tests/*.tftest.hcl`. | Add `northeurope` cases, assert `vm[*].zone == ["1","2"]`, assert one Key Vault Secrets User role assignment per VM (regression test for A1), and add a `db_mode = "vm"` plan case. | **1** |
| **C4** | **Flexible Server observability and safety knobs missing.** No `log_min_duration_statement` equivalent (the AWS parameter group sets it), no Performance-Insights analogue, no `deletion_protection` equivalent. | P2 | `modules/ha-hot-hot/aws/main.tf` `aws_db_parameter_group` + `rds_performance_insights_*` vs the Azure `azurerm_postgresql_flexible_server_configuration` (which only sets `require_secure_transport`). | Add server configurations for slow-query logging; consider `azurerm_management_lock` for delete protection. | **1** |
| **C5** | **Key Vault name collision after a destroy.** `purge_protection_enabled = true` with `soft_delete_retention_days = 30` and a name derived from `name_prefix`: destroying and re-creating the same-named stack inside 30 days fails, and purge protection means it cannot be force-purged. A real footgun during PoC iteration. | P2 | `modules/ha-hot-hot/azure/main.tf` `azurerm_key_vault.main`. | Document it prominently, or add a short random suffix to the vault name. Do **not** disable purge protection — disk encryption sets require it. | **0.5** |
| **C6** | **Marketplace image replication is not North Europe.** The Packer SIG destination replicates to `eastus` (SAT) / `centralus` (ASM). This is probably fine — Microsoft distributes a *published* offer to the regions the offer is enabled for — but nobody has confirmed the offer is enabled for North Europe in Partner Center. | P2 *(verification)* | `hailbytes-sat/scripts/packer/variables.pkr.hcl` `azure_replication_regions = ["eastus"]`; `hailbytes-asm/marketplace/packer/variables.pkr.hcl` `["centralus"]`. | Confirm in Partner Center that both offers are available in North Europe, then run `az vm image list --publisher lcmcon1687976613543 --offer gophish-phishing-simulator --all -l northeurope`. If not, it is a listing change, not a code change. | **0.5** to verify |

---

## What's real vs aspirational

**Real — verifiable from the code, and I would defend these in a customer call:**

- Two VMs in genuinely different availability zones (1 and 2), each with its own
  Premium_LRS OS and data disk.
- A Zone-Redundant PostgreSQL Flexible Server with enforced TLS, 14-day
  automated backups, VNet integration via a delegated subnet, and a
  `lifecycle` block that correctly ignores Azure-managed standby-zone drift.
  This is a true peer to RDS Multi-AZ.
- Key Vault with a 32-char generated password, RBAC-only data plane, purge
  protection, and secret rotation metadata.
- NSGs on both the LB and VM subnets, built from `allowed_cidrs`, with correct
  handling of Azure's one-NSG-per-subnet rule.
- An immutable, versioned, ZRS, Cool-tier backup container with lifecycle
  tiering and no shared-key access — the *container* is production-grade.
- Optional CMK for VM disks via a disk encryption set.
- Azure Monitor action group + LB availability alert.
- Marketplace-only image sourcing with the `plan` block and marketplace
  agreement handled correctly, publisher/offer consistency enforced in CI.
- CI that actually gates: `terraform validate` and `terraform test` on all six
  tier modules and all twelve wrappers, plus wrapper variable **and** output
  forwarding checks, `tflint`, `checkov`, `trivy`.

**Aspirational — described somewhere as working, but not working:**

- "The VM reads the DB password from Key Vault" (A1 — not authorized).
- "Shared session store" / "HA is safe because Redis is shared" (A2, A3 — the
  cache is unreachable and uncredentialed; `redis_mode` output reports
  `"managed"` regardless).
- "Zone-redundant Redis at Standard C1" (B4 — the tier does not offer it).
- "Pre-patch backup bundle lands in the immutable container" (A5).
- "Post-patch verification with a five-probe verifier" (A7 — zero probes run).
- "Azure NSG flow logs enabled by default" (B1).
- "LB access logs land in a Storage Account with a 90-day lifecycle" (B2).
- "Modules wire up Azure Bastion when `enable_management_access = true`" (B3).
- "Run command documents the customer fires from the Portal" (C2 —
  they execute at apply time).
- "~6× cost of single-vm" for the HA tier in `ARCHITECTURE.md` (it is ~2.9×;
  see [`AZURE_COST_SHAPES.md`](../AZURE_COST_SHAPES.md)).

**Untested rather than missing** — the whole module. There is no evidence in
the repo of a completed `terraform apply` against a live Azure subscription:
the CI comment states plainly that a real plan "needs credentials and is scoped
out of this workflow", the mock-provider tests cannot catch any of A1–A6, and
A1/A2/A4 are exactly the class of defect a single successful apply would have
surfaced in minutes.

---

## North Europe specifics

| Item | Status |
|---|---|
| Availability zones 1, 2, 3 | Available. The module's `["1","2"]` VM placement and `["1","2","3"]` public-IP/App-Gateway zones are valid. |
| `Standard_D2s_v5` | Offered — confirmed by a live Azure Retail Prices API response for `armRegionName eq 'northeurope'` on 2026-07-26. |
| `GP_Standard_D2ds_v5` Flexible Server | Offered — same source (`General Purpose Ddsv5 Series Compute`, `2 vCore`). |
| Flexible Server **ZoneRedundant HA** | Believed supported in North Europe, **not verified here.** Confirm with `az postgres flexible-server list-skus -l northeurope` before quoting; zone-redundant HA is region-gated and this is the single assumption the whole deal rests on. |
| Azure Cache for Redis Standard / Premium | Offered — retail prices returned for the region. |
| Application Gateway Standard_v2 / WAF_v2 | Offered — retail prices returned for the region. |
| Data residency | All managed services in the topology are regional. `postgres_geo_redundant_backup_enabled` defaults to `false`, so no backup leaves North Europe unless the customer opts in (paired region is West Europe). Backup Storage Account defaults to `ZRS` — zone-redundant *within* the region, not cross-region. Clean story for an EU education consortium. |
| Marketplace offer availability | **Unverified** — see gap C6. |

---

## What this audit could not test

Everything below needs a live subscription, and the P0 list is why:

1. Whether A1–A4 are the *only* data-path defects, or the first four of five.
2. Whether the Postgres private DNS zone name resolves correctly for a
   delegated-subnet server (C1).
3. Whether App Gateway's backend health probe accepts the image's self-signed
   certificate (A6).
4. Whether the marketplace offer deploys in North Europe at all (C6).
5. Whether `azurerm_virtual_machine_run_command` failing at apply time (which
   both Run Commands currently do) fails the whole `terraform apply` or merely
   records a non-zero exit — this changes whether a fresh apply even completes.

**Recommended next step: live validation in a scratch subscription in North
Europe.** The P0 code fixes are done and green in CI, but CI runs against mock
providers — it cannot tell you whether the private endpoint resolves, whether
App Gateway accepts the image's self-signed certificate (A6), whether the
Postgres private DNS zone name is right for a delegated-subnet server (C1), or
whether the marketplace offer is even available in North Europe (C6). Budget
**2–3 engineer-days** for an apply-and-observe pass; that is now the only thing
standing between this module and a demonstrable deployment.

---

## Related

- [`AZURE_PATCHING_AND_MIGRATION.md`](AZURE_PATCHING_AND_MIGRATION.md) — the Azure patch runbook, with manual workarounds for A5 and A7
- [`AZURE_COST_SHAPES.md`](../AZURE_COST_SHAPES.md) — North Europe pricing, including the NAT Gateway cost A4 introduces, the Premium-Redis delta (B4), and the customer-side savings B8 would unlock
- [`MARKETPLACE_IMAGE_ACCESS_AUDIT.md`](MARKETPLACE_IMAGE_ACCESS_AUDIT.md) — the no-retained-access claims, verified per claim
- [`PATCHING_AND_MIGRATION.md`](PATCHING_AND_MIGRATION.md) · [`../SECURITY-DEFAULTS.md`](../SECURITY-DEFAULTS.md) · [`../ARCHITECTURE.md`](../ARCHITECTURE.md) — documents with claims this audit contradicts
