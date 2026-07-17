# Patching and migration safety

This page documents the procurement-grade safety net that every HailBytes
Terraform module — AWS and Azure, single / HA / autoscale — ships with by
default. It is the URL we send to enterprise procurement and security
reviewers when they ask how patching, backups, and
rollback are handled in a BYOC deployment of HailBytes SAT or ASM.

The companion change in HailBytes SAT itself ships `/api/instance/export`,
`/api/instance/import`, and `scripts/ha-pre-patch-backup.sh` / `ha-post-patch-verify.sh`
(see `hailbytes-sat@c804cac` and
[`hailbytes-sat/docs/AWS_HA_DEPLOYMENT.md`](https://github.com/HailBytes/hailbytes-sat/blob/main/docs/AWS_HA_DEPLOYMENT.md)).
This repo wires those guarantees into the deployment topology.

---

## What the modules guarantee

For every customer deploying via these modules, the following is true on
day-one after `terraform apply` — no manual portal clicks, no extra
configuration:

| Guarantee | AWS implementation | Azure implementation |
|---|---|---|
| **Patches are customer-initiated.** | Module ships a Systems Manager Run Command document (`<prefix>-pre-patch-backup`) the customer fires from the AWS Console. HailBytes never has credentials. | Module installs an Azure Run Command document (`RunPrePatchBackup`) or VMSS extension the customer fires from the Portal. HailBytes never has credentials. |
| **HailBytes retains no admin access.** | No HailBytes SSH key, no IAM trust, no phone-home; structurally enforced by BYOC architecture and verified by the absence of any `arn:aws:iam::HAILBYTES_ACCOUNT_ID:*` principal in the modules' IAM. | No HailBytes service principal, no shared SAS token; verified by absence of any `hailbytes.com` tenant in role assignments. |
| **No expected data loss from patching.** | Pre-patch backup bundle (DB + uploads + manifest, gzipped tarball) lands in an S3 bucket with versioning + Object Lock (governance) + lifecycle to IA at 30d / Deep Archive at 90d. RDS snapshot taken alongside. | Same bundle lands in a Storage Account container with blob versioning + immutable (unlocked) policy + lifecycle to Cool at 30d / Archive at 90d. Flexible Server on-demand backup taken alongside. |
| **Auto-rollback on bad upgrade.** | Autoscale tier: ASG Instance Refresh with `min_healthy_percentage = 50`, `auto_rollback = true`, `skip_matching = true`, and `alarm_specification` tied to ALB 5xx-rate and unhealthy-host CloudWatch alarms. HA tier: same alarms wired to SNS for operator-initiated rollback. | Autoscale tier: VMSS rolling upgrade with `automatic_instance_repair` + `max_unhealthy_instance_percent`, paired with Azure Monitor metric alerts on App Gateway 5xx and VMSS `VmAvailabilityMetric`. HA tier: equivalent alerts wired to an Action Group. |
| **Schema-version probe for CI/CD.** | `module.<name>.schema_version_endpoint` = `https://<alb>/api/instance/schema-version`. | `module.<name>.schema_version_endpoint` = `https://<lb-or-appgw>/api/instance/schema-version`. |
| **WAF supported but not bundled.** | Optional `var.waf_web_acl_arn` attaches a customer-supplied WAFv2 web ACL to the ALB. | Optional `var.waf_policy_id` attaches a customer-supplied Web Application Firewall policy to the Application Gateway (which the module provisions when `var.enable_application_gateway = true`). |

---

## Rolling-replace flow — what the customer sees

1. **Customer reviews the published HailBytes AMI / image version.** AWS:
   `aws ec2 describe-images --owners aws-marketplace --filters
   Name=product-code,Values=d19hjbz3gakqdlonlf8twdmll` (the SAT product
   code from
   [`MARKETPLACE.md`](https://github.com/HailBytes/hailbytes-sat/blob/main/MARKETPLACE.md)).
   Azure: `az vm image list --publisher lcmcon1687976613543 --offer
   gophish-phishing-simulator --all`.
2. **Customer fires the pre-patch backup.**
   - AWS Console → Systems Manager → Run Command → select
     `module.<name>.pre_patch_ssm_document_name`. Targets instances
     tagged `hailbytes-sat=true` (or `hailbytes-asm=true`).
   - Azure Portal → the SAT VM → Operations → Run command → select
     `RunPrePatchBackup`. For VMSS, use
     `az vmss run-command invoke --command-id RunShellScript --vmss-name <vmss>`.
3. **The Run Command does three things, all observable in logs:**
   1. Calls `/opt/hailbytes/bin/ha-pre-patch-backup.sh` on the VM. The
      script produces a gzipped tar containing `bundle.json` + `db.sql`
      (`pg_dump --format=plain --no-owner --no-privileges --clean
      --if-exists`) + `uploads/`, stamped with a SHA-256 fingerprint of
      `HAILBYTES_ENCRYPTION_KEY` in the manifest.
   2. Uploads the tarball to the backup bucket / container under
      `hailbytes-{sat,asm}-<timestamp>.tar.gz`. Object Lock / immutable
      blob policy makes it tamper-evident for the configured retention
      window.
   3. Takes a database snapshot (RDS create-db-snapshot or Azure
      Flexible Server on-demand backup, depending on `var.db_mode`).
4. **Customer re-runs `terraform apply`.** The module's marketplace AMI
   lookup (`data.aws_ami.hailbytes` filtered on product code) resolves to
   the newer AMI; `terraform plan` shows a launch-template / VMSS image
   change. The autoscale tier's `instance_refresh` (AWS) or
   `rolling_upgrade_policy` (Azure VMSS) kicks off rolling replacement.
5. **CloudWatch / Azure Monitor watches the patch.** If the new AMI
   trips the 5xx-rate or unhealthy-host alarm during the refresh window,
   AWS aborts the refresh and rolls back to the previous launch template.
   On Azure, the rolling upgrade pauses and the customer is alerted; they
   can `az vmss rolling-upgrade cancel` to roll back manually.
6. **Customer (or their CI/CD) runs post-patch verify.** The
   `scripts/ha-post-patch-verify.sh` from the SAT repo curls
   `module.<name>.schema_version_endpoint`, validates `/api/ready`, and
   confirms the encryption-key fingerprint matches what was recorded in
   the pre-patch bundle manifest.

If a rollback happens, the immutable pre-patch bundle in S3 / Azure
Storage is still there. The customer can spin up a fresh SAT stack via
this Terraform, point it at the same encryption key (carry-over) and
RDS / Flexible Server, and POST the bundle to `/api/instance/import` on
the new stack to restore.

---

## Pulling a bundle for off-deployment retention

Some procurement frameworks (UK G-Cloud, FedRAMP-adjacent) require
that backup artifacts live outside the production account. The modules
emit a clean copy path for that:

```bash
# AWS
aws s3 cp \
  "$(terraform output -raw backup_s3_uri_prefix)2026-05-18T12-30-00Z.tar.gz" \
  s3://my-cold-storage-account/hailbytes-sat/2026-05-18.tar.gz

# Azure
az storage blob copy start \
  --source-uri "$(terraform output -raw backup_container_uri)2026-05-18T12-30-00Z.tar.gz" \
  --destination-container archive --destination-blob hailbytes-sat-2026-05-18.tar.gz \
  --account-name mycoldarchive
```

Both backup stores enforce least-privilege writes (`s3:PutObject` /
Storage Blob Data Contributor restricted to the `hailbytes-*` prefix and
the SAT VM's role / managed identity), so this cross-account copy is the
only sanctioned exfiltration path.

---

## Restoring from a bundle into a fresh stack

This is the procurement-grade test for "no data loss from patching." It
also happens to be the disaster-recovery runbook.

1. Provision a fresh SAT stack via Terraform — same product, same tier:

   ```hcl
   module "hailbytes_sat_restore" {
     source = "github.com/hailbytes/hailbytes-terraform-modules//modules/sat-aws-ha?ref=v1.0.0"

     vpc_id              = var.vpc_id
     public_subnet_ids   = var.public_subnets
     private_subnet_ids  = var.private_subnets
     allowed_cidrs       = var.allowed_cidrs
     acm_certificate_arn = var.cert_arn

     # Critical: reuse the old deployment's encryption key.
     # The bundle.json manifest contains a SHA-256 fingerprint; mismatch
     # will refuse the import. The encryption key itself is NOT in the
     # bundle (by design — restoring requires both halves).
   }
   ```

2. Configure the new stack with the previous deployment's
   `HAILBYTES_ENCRYPTION_KEY`. Push it to AWS Secrets Manager (the same
   secret name the marketplace AMI mounts) or Azure Key Vault before the
   VMs come up.

3. Pre-create the database. For AWS, RDS is provisioned by Terraform; for
   Azure, the Flexible Server is too. No additional action required.

4. Upload the bundle to the new stack:

   ```bash
   curl -X POST \
     -H "Authorization: Bearer $ADMIN_TOKEN" \
     -F bundle=@hailbytes-sat-2026-05-18.tar.gz \
     "https://$(terraform output -raw alb_dns_name)/api/instance/import"
   ```

   `/api/instance/import` validates the encryption-key fingerprint,
   replays `db.sql`, restores `uploads/`, and reports success. The
   underlying mechanics live in
   [hailbytes-sat/docs/AWS_HA_DEPLOYMENT.md](https://github.com/HailBytes/hailbytes-sat/blob/main/docs/AWS_HA_DEPLOYMENT.md);
   we do not duplicate them here.

---

## DB mode toggle (HA tier)

The HA modules expose a `var.db_mode` toggle for customers who must keep
the database on a VM they control (compliance, BYO-DBA, simplification):

| `db_mode` | AWS HA | Azure HA |
|---|---|---|
| `rds` (default, AWS) / `flexible_server` (default, Azure) | Multi-AZ `db.t3.medium` RDS, encrypted, automated backups | Zone-Redundant Postgres Flexible Server, encrypted, automated backups |
| `ec2` (AWS) / `vm` (Azure) | Third EC2, Ubuntu 24.04 + apt-installed PostgreSQL 16, encrypted gp3 volume | Third Linux VM, Ubuntu 24.04 + apt-installed PostgreSQL 16, Premium_LRS data disk |

The Secrets Manager / Key Vault payload format is identical across both
modes, so the SAT marketplace VM bootstraps without branching. The
variable names mirror the Cloud Shell deploy script's
`HAILBYTES_DB_MODE` for consistency.

The autoscale tier does not offer this toggle — at scale-out sizing
(`asg_max_size >= 3`, multiple read replicas), a single self-managed
Postgres EC2 is not a sensible architecture.

---

## Variable reference

Every safety-net knob has a backward-compatible default. A customer
upgrading from a pre-patching-safety pin gets the new bucket / SSM doc /
alarms automatically on next `terraform apply`. Set
`create_backup_bucket = false` / `create_backup_storage_account = false`
to opt out (e.g., if your org enforces backups via a central data
protection service).

| Variable | AWS default | Azure default | Notes |
|---|---|---|---|
| `create_backup_bucket` / `create_backup_storage_account` | `true` | `true` | Set false to opt out of the module-provisioned backup store. |
| `backup_bucket_name` / `backup_storage_account_name` | null | null | Override the auto-generated name; can point at an existing bucket. |
| `backup_object_lock_retention_days` / `backup_immutability_days` | 30 | 30 | Governance / unlocked, so operators can extend. |
| `instance_refresh_min_healthy_percentage` (AWS autoscale only) | 50 | — | Drains one instance at a time on a 2-instance ASG. |
| `instance_refresh_instance_warmup_seconds` (AWS autoscale only) | 120 | — | Enough for the SAT AMI to pass ALB /health. |
| `refresh_rollback_5xx_threshold_pct` (AWS) / `refresh_rollback_5xx_count_threshold` (Azure) | 1 (percent) | 50 (count) | Different metric shapes — AWS is a rate, Azure is a count. |
| `rolling_upgrade_max_batch_percent` / `rolling_upgrade_max_unhealthy_percent` (Azure autoscale only) | — | 20 | VMSS rolling-upgrade equivalent of AWS instance refresh percentages. |
| `waf_web_acl_arn` (AWS) / `waf_policy_id` (Azure) | null | null | Optional. Azure additionally requires `enable_application_gateway = true`. |
| `enable_application_gateway` (Azure HA + autoscale) | — | `false` | Stands up App Gateway in front of the Standard LB. Required for WAF parity. |
| `db_mode` (HA only) | `rds` | `flexible_server` | Alternative is `ec2` / `vm`. |
| `rds_backup_retention_period` (AWS HA) | 7 | — | Days RDS retains automated daily backups. |
| `db_backup_retention_days` (Azure HA Flexible Server) | — | 14 | Days Flexible Server retains automated backups. |

---

## Audit pointers

For procurement / security reviewers verifying the claims on this page:

1. **No HailBytes admin access.** Search the modules for any IAM trust
   policy or role assignment referencing a non-customer principal. There
   are none. The only inbound trust is to `ec2.amazonaws.com` (instance
   role), `vpc-flow-logs.amazonaws.com` (flow log role), and `dlm.amazonaws.com`
   (snapshot lifecycle role) — all customer-controlled.
2. **No phone-home.** Search for outbound endpoints in `user_data` /
   `custom_data` / cloud-init. There are none other than (a) AWS APIs
   the instance hits via its own instance profile, (b) the AWS
   marketplace metering endpoint (mandatory for billing), and (c) Azure
   Instance Metadata. None reach a HailBytes-controlled service.
3. **Patches are customer-initiated.** Search for any scheduled patching
   automation: `aws_cloudwatch_event_rule`, `azurerm_automation_schedule`,
   cron lines in cloud-init. There are none. The SSM / Run Command
   documents exist but require a customer to invoke them.
4. **No HailBytes-controlled SSH key.** Search for `key_name` /
   `admin_ssh_key` defaults. They take the customer's input only;
   nothing is hardcoded.

A summary of all the above lives in `SECURITY-DEFAULTS.md`.

---

## Related

- HailBytes SAT runbook (the underlying mechanics): [`hailbytes-sat/docs/AWS_HA_DEPLOYMENT.md`](https://github.com/HailBytes/hailbytes-sat/blob/main/docs/AWS_HA_DEPLOYMENT.md)
- Marketplace identifiers: [`hailbytes-sat/MARKETPLACE.md`](https://github.com/HailBytes/hailbytes-sat/blob/main/MARKETPLACE.md)
- Security defaults baked into modules: [`SECURITY-DEFAULTS.md`](../SECURITY-DEFAULTS.md)
- Architecture diagrams per tier: [`ARCHITECTURE.md`](../ARCHITECTURE.md)
