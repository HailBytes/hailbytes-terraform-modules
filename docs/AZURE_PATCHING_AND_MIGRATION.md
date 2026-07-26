# Patching and migration safety — Azure

Azure companion to [`PATCHING_AND_MIGRATION.md`](PATCHING_AND_MIGRATION.md).
That page is written cloud-neutral but every mechanism in it that has been
exercised end-to-end is the AWS one; this page is the Azure procedure in the
same shape, so the two read as a pair.

The companion change in HailBytes SAT itself ships `/api/instance/export`,
`/api/instance/import`, `/api/instance/schema-version`, and
`scripts/ha-pre-patch-backup.sh` / `ha-post-patch-verify.sh`. This repo wires
those into the Azure topology.

> [!WARNING]
> **Two of the mechanisms below are wired but non-functional on Azure today.**
> The pre-patch backup Run Command cannot produce a bundle, and the post-patch
> verify Run Command exits before running a single probe. Both are marked
> ⛔ **BLOCKED** at the point of use, with the exact reason and the manual
> procedure to use instead. Do not hand this page to a customer as an
> as-built description until the ⛔ items clear — hand them the manual
> procedures, which do work. Detail and remediation effort:
> [`AZURE_HA_PARITY_AUDIT.md`](AZURE_HA_PARITY_AUDIT.md).

---

## What the modules guarantee

Status column: ✅ works today · ⚠️ works with caveats · ⛔ blocked.

| Guarantee | Azure implementation | Status |
|---|---|---|
| **Patches are customer-initiated.** | Nothing in the modules schedules an image change. No `azurerm_automation_schedule`, no cron in `custom_data`, no Update Manager maintenance configuration. Image version is pinned by `var.marketplace_image_version`; only a customer-run `terraform apply` moves it. | ✅ |
| **HailBytes retains no admin access.** | No HailBytes service principal, no shared SAS token, no HailBytes tenant in any `azurerm_role_assignment`. Every role assignment targets either the caller running `terraform apply` (`data.azurerm_client_config.current.object_id`), the module's own disk-encryption-set identity, or a VM's system-assigned identity. | ✅ |
| **No expected data loss from patching.** | Bundle should land in a Storage Account container with blob versioning + an unlocked immutability policy + lifecycle to Cool at 30 d / Archive at 90 d, with a Flexible Server on-demand backup alongside. The container, policies and lifecycle **are** provisioned; the script that fills them is AWS-only. | ⛔ see [Pre-patch backup](#step-2--pre-patch-backup) |
| **Rolling replace keeps capacity at 50%.** | Two standalone zonal VMs behind a Standard Load Balancer. There is no VMSS on this tier, so no `rolling_upgrade_policy` and no `automatic_instance_repair` — the operator replaces one VM at a time with `-target`. A plain `terraform apply` after bumping a pinned image version **replaces both VMs in the same apply**. | ⚠️ see [Step 3](#step-3--rolling-replace-one-vm-at-a-time) |
| **Schema migrations are serialised.** | The SAT/ASM binary takes a Postgres session-level advisory lock (`pg_advisory_lock(7426893184710137)`) around its goose migration run, so both VMs booting on a new image at once cannot race the same DDL. Cloud-independent — this is application behaviour, and it is the one part of the story that is identical on AWS and Azure. | ✅ see [Step 4](#step-4--schema-migrations-under-the-advisory-lock) |
| **Post-patch schema-version verification.** | `module.<name>.schema_version_endpoint` → `https://<lb-or-appgw>/api/instance/schema-version`, and the image ships the five-probe verifier at `/opt/hailbytes/bin/ha-post-patch-verify.sh`. The Run Command that should invoke it calls it with no arguments, which the script rejects. | ⛔ see [Step 5](#step-5--post-patch-verification) |
| **Auto-rollback on a bad upgrade.** | HA tier: Azure Monitor metric alerts on LB `VipAvailability` and (when App Gateway is enabled) backend 5xx count, wired to an Action Group, for **operator-initiated** rollback. There is no automatic rollback on this tier — the autoscale tier's VMSS `automatic_instance_repair` is the closest Azure gets, and this tier has no VMSS. | ⚠️ see [Step 6](#step-6--rollback) |
| **WAF supported but not bundled.** | `var.waf_policy_id` attaches a customer-supplied WAF policy to the Application Gateway, which the module provisions when `enable_application_gateway = true`. Azure WAF cannot attach to a Standard Load Balancer — it is L4 only — so WAF on Azure is strictly an App Gateway feature. | ✅ |

---

## Rolling-replace flow — what the customer sees

### Step 1 — Review the published image version

```bash
# What versions exist for the SAT offer?
az vm image list \
  --publisher lcmcon1687976613543 \
  --offer gophish-phishing-simulator \
  --all -o table

# ASM: --offer hardened_ubuntu_with_rengine
```

Record the version you intend to move to. **Pin it** — set
`marketplace_image_version = "1.1435.3"` rather than leaving the `"latest"`
default. With `"latest"`, Terraform stores the literal string, sees no drift,
and never plans a replacement; you lose the ability to see the patch in
`terraform plan`, and a manually reimaged VM silently lands on a different
build than its peer. Pinning is what makes the rest of this runbook
observable.

### Step 2 — Pre-patch backup

⛔ **BLOCKED: `RunPrePatchBackup` cannot produce a bundle on Azure.**

Two independent reasons, both in
`modules/ha-hot-hot/azure/main.tf` (`azurerm_virtual_machine_run_command.pre_patch_backup`):

1. **The script has no Azure Blob support.** `ha-pre-patch-backup.sh` uploads
   only when `AWS_S3_BUCKET` is set, via `aws s3 cp`. The Run Command exports
   `AZURE_STORAGE_ACCOUNT`, `AZURE_STORAGE_CONTAINER` and `AZURE_BLOB_PREFIX`
   — three variables the script never reads. Best case the bundle stays on the
   VM's local disk at `/var/backups/hailbytes-sat/`, which is the disk you are
   about to replace.
2. **The script's required environment is not passed.** It needs
   `HAILBYTES_SAT_DB_HOST`, `HAILBYTES_SAT_DB_USER`, `HAILBYTES_SAT_DB_NAME`
   and `PGPASSWORD`; the Run Command sets none of them and the script exits 1
   before `pg_dump` runs.

Also note that `azurerm_virtual_machine_run_command` is not an on-demand
document like an SSM document — **the script body executes when Terraform
creates the resource**, i.e. during the initial `terraform apply`. The Portal's
Run command blade lets you re-run a script, but the resource itself is not a
"document sitting there waiting to be fired", and `PATCHING_AND_MIGRATION.md`
describes it as if it were.

**Use this instead, until that is fixed.** Run it from either app VM over SSH
(or Azure Bastion). It is the same script the Run Command was meant to invoke,
given the environment it actually asks for, plus an explicit blob upload.

```bash
# On app VM #1.
set -euo pipefail
TS=$(date -u +%Y-%m-%dT%H-%M-%SZ)

# 1. DB coordinates. In flexible_server mode this is the module's
#    postgres_fqdn output; in db_mode = "vm" it is the DB VM's private IP.
export HAILBYTES_SAT_DB_HOST='<terraform output -raw postgres_fqdn>'
export HAILBYTES_SAT_DB_USER='hailbytes'
export HAILBYTES_SAT_DB_NAME='hailbytes'
export HAILBYTES_SAT_DB_PORT=5432

# 2. Password from Key Vault via the VM's managed identity.
TOKEN=$(curl -sS -H Metadata:true \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://vault.azure.net" \
  | jq -r .access_token)
export PGPASSWORD=$(curl -sS -H "Authorization: Bearer $TOKEN" \
  "<terraform output -raw key_vault_uri>secrets/hailbytes-db-password?api-version=7.4" \
  | jq -r .value)

# 3. Bundle to local disk (pg_dump + uploads + manifest with the
#    encryption-key fingerprint).
export BACKUP_DIR=/var/backups/hailbytes-sat
sudo -E /opt/hailbytes/bin/ha-pre-patch-backup.sh

# 4. Upload to the immutable container yourself — this is the step the
#    script cannot do. Managed-identity auth; the module already granted
#    the VM identity Storage Blob Data Contributor on this account.
BUNDLE=$(ls -t "$BACKUP_DIR"/*.tar.gz | head -1)
az login --identity --allow-no-subscriptions >/dev/null
az storage blob upload \
  --auth-mode login \
  --account-name "$(terraform output -raw backup_storage_account_name)" \
  --container-name "hailbytes-sat-bundles" \
  --name "hailbytes-sat-${TS}.tar.gz" \
  --file "$BUNDLE"
```

Then take the database snapshot — this half of the Run Command is correct and
can be run as-is:

```bash
# flexible_server mode
az postgres flexible-server backup create \
  --resource-group '<rg>' --name '<prefix>-pg' \
  --backup-name "<prefix>-pre-patch-${TS}"

# db_mode = "vm"
az snapshot create \
  --resource-group '<rg>' --name "<prefix>-db-pre-patch-${TS}" \
  --source '<data disk id>' --incremental true \
  --tags Module=hailbytes-terraform-modules Phase=pre-patch
```

Verify the blob landed before going further. The container carries an unlocked
immutability policy (`backup_immutability_days`, default 30) and blob
versioning, so once it is there it is tamper-evident for the retention window.

```bash
az storage blob list --auth-mode login \
  --account-name "$(terraform output -raw backup_storage_account_name)" \
  --container-name hailbytes-sat-bundles -o table
```

### Step 3 — Rolling replace, one VM at a time

**Azure HA is two standalone zonal VMs, not a scale set.** There is no
instance-refresh and no rolling-upgrade policy on this tier. Two consequences,
both different from AWS:

- The AWS HA module sets `lifecycle { ignore_changes = [ami, user_data] }` on
  its instances, so a new AMI never plans a replacement — the operator taints
  deliberately. **The Azure module sets no `lifecycle` block on
  `azurerm_linux_virtual_machine.vm`**, so bumping a pinned
  `marketplace_image_version` plans a replacement of *both* VMs, and
  `terraform apply` will execute both in one run. That is a full outage, not a
  rolling patch.
- Therefore: **always drive this tier with `-target`, one VM per apply.**

```bash
# 0. Confirm the plan touches exactly what you expect, and note that BOTH
#    VMs are queued for replacement.
terraform plan

# 1. Drain VM #1 from the load balancer by stopping the app. The LB probe
#    is /health every 15 s with number_of_probes = 2, so the backend is
#    taken out of rotation ~30 s after /health starts failing. There is no
#    deregistration-delay setting on an Azure LB rule — the probe interval
#    IS the drain window. Wait for it before proceeding.
ssh hbadmin@<vm1-private-ip> 'sudo systemctl stop hailbytes-sat'
sleep 45

# 2. Confirm VM #2 is carrying all traffic.
curl -sk "https://$(terraform output -raw load_balancer_public_ip)/health"

# 3. Replace VM #1 only.
terraform apply -target='module.hailbytes_sat.azurerm_linux_virtual_machine.vm[0]'

# 4. VM #1 boots on the new image, runs bootstrap, takes the migration
#    advisory lock (Step 4), migrates, and starts serving. Wait for the LB
#    to mark it healthy again — two successful probes, ~30 s.
az network lb show --resource-group '<rg>' --name '<prefix>-lb' \
  --query 'probes[0].name' -o tsv

# 5. Verify VM #1 (Step 5) BEFORE touching VM #2. This is the whole point of
#    the rolling procedure: a bad image should cost you one VM, not two.

# 6. Repeat 1–5 for vm[1].
```

If `enable_application_gateway = true`, the App Gateway backend pool is built
from `azurerm_network_interface.vm[*].private_ip_address`, so the pool
membership survives an in-place VM replacement only if the NIC keeps its IP —
allocation is `Dynamic`, so it usually does but is not guaranteed. Re-check the
App Gateway backend health after each replacement:

```bash
az network application-gateway show-backend-health \
  --resource-group '<rg>' --name '<prefix>-appgw' -o table
```

> **App Gateway + the marketplace image's self-signed certificate.** The module
> configures `backend_http_settings` with `protocol = "Https"` to the VMs, and
> the VMs present a self-signed certificate generated on first boot. App Gateway
> v2 validates backend certificates; without a matching entry in
> `trusted_root_certificate_names` the probe fails and the gateway returns 502.
> Verify backend health on a non-production stack before relying on this path
> during a patch window.

### Step 4 — Schema migrations under the advisory lock

This is the mechanism that makes a rolling patch safe when the new image
carries migrations, and it is identical on both clouds because it lives in the
application, not the infrastructure.

On every boot, before serving traffic, the binary:

1. Opens its Postgres connection and reconciles the pool against the server's
   `max_connections`.
2. Executes `SELECT pg_advisory_lock(7426893184710137)` — a **session-level**
   advisory lock, keyed on a hash of `hailbytes_sat_migrations`
   (`models/models.go`).
3. Runs `goose.RunMigrationsOnDb(...)` up to the latest version.
4. Releases the lock via `defer` / `pg_advisory_unlock`.

Why it matters on Azure specifically: after a zone outage or a two-VM
replacement, both VMs can boot within seconds of each other against the same
Flexible Server. Goose's `goose_db_version` table is INSERT-tracked and so is
already safe from double-applying a migration, but *unlocked concurrent DDL*
on a shared managed Postgres produces `lock_timeout` cascades that fail boot
outright. The advisory lock turns that race into a queue: the second VM blocks
on the lock, then finds the schema already current and proceeds.

Operational notes:

- **The lock is session-level, not transaction-level.** It is released when the
  connection closes, so a VM that is killed mid-migration never leaves the lock
  held — the next boot acquires it. There is no stuck-lock recovery step.
- **Acquisition failure is a soft failure.** If the `pg_advisory_lock` call
  itself errors, the code logs
  `could not acquire migration advisory lock (proceeding without it)` at WARN
  and migrates anyway. Grep the boot log for that string after a patch: it
  means the serialisation guarantee did not apply to that boot.
- **Confirm serialisation actually happened** on the second VM's boot:

  ```bash
  # On the VM that booted second.
  sudo journalctl -u hailbytes-sat -b | grep -iE 'advisory lock|goose|migrat'
  ```

- **Watch the lock live** during a patch window, from any psql session against
  the shared server:

  ```sql
  SELECT pid, granted, classid, objid
    FROM pg_locks
   WHERE locktype = 'advisory';
  ```

- **The lock does not make migrations backward-compatible.** It serialises them;
  it does not stop a destructive migration from breaking the peer VM that is
  still running the old binary. That is why Step 3 verifies one VM before
  replacing the second, and why the pre-patch bundle exists.

### Step 5 — Post-patch verification

⛔ **BLOCKED: `RunPostPatchVerify` exits before running any probe.**

`ha-post-patch-verify.sh` takes the admin host as a **positional argument**
(`Usage: $0 <admin-host> [<admin-port>]`) and exits 1 when called with none.
The Azure Run Command
(`azurerm_virtual_machine_run_command.post_patch_verify`) invokes
`sudo -E /opt/hailbytes/bin/ha-post-patch-verify.sh` with no arguments, so
every invocation exits 1 having tested nothing. It exports
`HAILBYTES_SCHEMA_VERSION_PATH`, which the script does not read. The AWS SSM
document has the identical defect, so this is not an Azure-only regression.

**Run it by hand, per VM, after each replacement:**

```bash
# From an operator host that can reach the VM, or on the VM itself.
export HAILBYTES_ADMIN_API_KEY='<api key with modify-system permission>'
export PRE_PATCH_MANIFEST=/var/backups/hailbytes-sat/bundle.json   # from Step 2
export HAILBYTES_ENCRYPTION_KEY='<the deployment key>'

/opt/hailbytes/bin/ha-post-patch-verify.sh <vm-private-ip> 3333; echo "exit=$?"
```

The five probes and what a failure means:

| Exit | Probe | Interpretation |
|---|---|---|
| 0 | all | Safe to proceed to the second VM. |
| 2 | `/api/ready` non-200 | The new image is not serving. Do not replace the second VM. |
| 3 | schema-version regression | The running `goose_db_version` is **older** than the pre-patch bundle's, or unreadable while a manifest was supplied. A rolled-back image against a forward-migrated schema. Highest-severity outcome — go to [Step 6](#step-6--rollback). |
| 4 | encryption-key fingerprint mismatch | The new VM is using a different `HAILBYTES_ENCRYPTION_KEY` than the pre-patch bundle recorded. Existing encrypted columns will not decrypt. Stop; fix the key before touching VM #2. |
| 5 | worker lock stuck | The worker-lock TTL expired with no liveness updates — usually the shared Redis endpoint is unreachable from the new VM. On Azure this is worth checking first, because the module's `azurerm_redis_cache` sets `public_network_access_enabled = false` with no private endpoint. |
| 6 | sample SMTP decrypt failed | Decryption is broken even though the fingerprint matched. Treat as data-affecting. |

The schema-version endpoint on its own, for a CI/CD gate:

```bash
curl -sk -H "Authorization: Bearer $HAILBYTES_ADMIN_API_KEY" \
  "$(terraform output -raw schema_version_endpoint)"
# {"version":20260518120000,"source":"goose_db_version"}
```

> `/api/instance/schema-version` is gated by `RequirePermission(PermissionModifySystem)`.
> An unauthenticated curl gets a 401, not a version — pass an admin API key.
> The `schema_version_endpoint` output points at the LB or App Gateway frontend,
> which in the default Standard-LB topology terminates TLS on the VM's
> self-signed certificate; `-k` or a pinned CA is required.

### Step 6 — Rollback

There is no automatic rollback on the Azure HA tier. What the module gives you
is detection plus a fast manual path.

**Detection** — provisioned when `alert_email` is set:

| Alert | Signal | Fires when |
|---|---|---|
| `<prefix>-lb-unhealthy-backends` | `Microsoft.Network/loadBalancers` → `VipAvailability` < 100, avg over 5 min, evaluated every 1 min | A backend is out of rotation. Expected to fire briefly during every rolling patch — that is the point; if it *stays* firing after the VM should be back, the new image is not passing `/health`. |
| `<prefix>-appgw-5xx-rate` | `BackendResponseStatus` where `BackendHttpStatus = 5xx`, total over 5 min > `refresh_rollback_5xx_count_threshold` (default 10) | Only exists when `enable_application_gateway = true`. Note it is a **count**, not a rate — tune it to site traffic or it will either never fire or never stop. |

**Rollback procedure.** Because you replaced one VM at a time, the peer is
still running the previous image and still serving:

```bash
# 1. Point the pinned version back at the previous build.
#    marketplace_image_version = "<previous version>"

# 2. Re-replace only the VM you just patched.
terraform apply -target='module.hailbytes_sat.azurerm_linux_virtual_machine.vm[0]'

# 3. Re-run Step 5 against the rolled-back VM.
```

**If the migration already ran, rolling the image back is not enough.** The
schema is forward of the old binary. That is the exit-3 case, and the recovery
is a restore, not a rollback:

1. Restore the database — Flexible Server point-in-time restore to just before
   the patch window, or the on-demand backup from Step 2:

   ```bash
   az postgres flexible-server restore \
     --resource-group '<rg>' --name '<prefix>-pg-restored' \
     --source-server '<prefix>-pg' \
     --restore-time '2026-07-26T09:15:00Z'
   ```

   This creates a **new server**; repoint `db_delegated_subnet_id` consumers or
   plan a cutover. It is not an in-place operation.
2. Or stand up a fresh stack and import the pre-patch bundle — see
   [Restoring from a bundle](#restoring-from-a-bundle-into-a-fresh-stack).

This is the scenario the pre-patch bundle exists for, and it is the scenario
that the ⛔ in Step 2 leaves you exposed to. Until Step 2 is fixed, treat every
Azure patch that carries a migration as requiring a **manually verified** bundle
in the Storage Account before you start.

---

## Pulling a bundle for off-deployment retention

Some procurement frameworks (UK G-Cloud, FedRAMP-adjacent) require backup
artifacts to live outside the production subscription.

```bash
az storage blob copy start \
  --source-uri "$(terraform output -raw backup_container_uri)2026-07-26T09-30-00Z.tar.gz" \
  --destination-container archive \
  --destination-blob hailbytes-sat-2026-07-26.tar.gz \
  --account-name mycoldarchive
```

The module grants each app VM's managed identity `Storage Blob Data Contributor`
on the backup account and nothing wider, and the account has
`shared_access_key_enabled = false` and `public_network_access_enabled = false`,
so this cross-subscription copy is the only sanctioned egress path for backup
data.

---

## Restoring from a bundle into a fresh stack

The procurement-grade test for "no data loss from patching", and the DR runbook.

1. Provision a fresh stack — same product, same tier. Pin the image version you
   want, not `"latest"`.

   > No `v1.0.0` tag exists yet ([#48](https://github.com/HailBytes/hailbytes-terraform-modules/issues/48)); pin to a commit SHA instead of `?ref=v1.0.0`.

   ```hcl
   module "hailbytes_sat_restore" {
     source = "github.com/hailbytes/hailbytes-terraform-modules//modules/sat-azure-ha?ref=<sha>"

     resource_group_name    = var.resource_group_name
     location               = "northeurope"
     vm_subnet_id           = module.network.workload_subnet_id
     lb_subnet_id           = module.network.lb_subnet_id
     db_delegated_subnet_id = module.network.db_delegated_subnet_id
     private_dns_zone_id    = module.network.private_dns_zone_id
     allowed_cidrs          = var.allowed_cidrs
     admin_username         = var.admin_username
     ssh_public_key         = var.ssh_public_key

     # Critical: the restore must reuse the old deployment's encryption key.
     # bundle.json carries a SHA-256 fingerprint of it; a mismatch makes
     # /api/instance/import refuse the bundle. The key itself is NOT in the
     # bundle — restoring deliberately requires both halves.
   }
   ```

2. Put the previous deployment's `HAILBYTES_ENCRYPTION_KEY` in place **before
   the VMs come up**. The marketplace image's `bootstrap.sh` generates a fresh
   key on first boot only when the env file has none, and it explicitly refuses
   to overwrite an existing one — so seed
   `/opt/hailbytes-sat/hailbytes-sat.env` (or `/etc/hailbytes-sat/env`, which
   the systemd unit loads last and which is the intended HA override path) with
   the old key before first start. If you let a VM boot first and generate its
   own key, the import will fail the fingerprint check and you will have to
   rebuild the VM.

3. The database is provisioned by Terraform in both `db_mode`s — no extra step.

4. Upload the bundle:

   ```bash
   curl -k -X POST \
     -H "Authorization: Bearer $ADMIN_TOKEN" \
     -F bundle=@hailbytes-sat-2026-07-26.tar.gz \
     "https://$(terraform output -raw load_balancer_public_ip)/api/instance/import"
   ```

   `/api/instance/import` validates the fingerprint, replays `db.sql`, restores
   `uploads/`, and reports success. Mechanics live in the SAT repo; not
   duplicated here.

5. Confirm with Step 5's verifier against both VMs, then cut DNS over.

---

## DB mode toggle (HA tier)

| `db_mode` | What you get | Patch implications |
|---|---|---|
| `flexible_server` (default) | Zone-Redundant PostgreSQL Flexible Server, encrypted, automated backups (`db_backup_retention_days`, default 14), point-in-time restore, on-demand backups | Pre-patch DB snapshot is a one-liner; rollback has PITR. This is the mode this runbook assumes. |
| `vm` | A third Linux VM, Ubuntu 24.04 + apt-installed PostgreSQL 16 on a Premium_LRS data disk | No automated backups, no PITR, no zone-redundant failover. Pre-patch protection is a managed-disk snapshot only, and restore means attaching a snapshot to a new VM. Also carries the per-vCPU Marketplace meter — see [`AZURE_COST_SHAPES.md`](../AZURE_COST_SHAPES.md). |

The Key Vault secret format is identical in both modes (`hailbytes-db-password`
in the module's vault), so the marketplace image bootstraps without branching.

The autoscale tier does not offer this toggle: at VMSS sizing with read
replicas, a single self-managed Postgres VM is not a sensible architecture.

---

## Variable reference

Every knob has a backward-compatible default; a customer upgrading from an
earlier pin gets the backup container, Run Commands and alerts on their next
`terraform apply`.

| Variable | Azure default | Notes |
|---|---|---|
| `marketplace_image_version` | `"latest"` | **Pin it.** `"latest"` makes the patch invisible to `terraform plan`. |
| `create_backup_storage_account` | `true` | Set false if a central data-protection service owns backups. |
| `backup_storage_account_name` | `null` | Point at an existing account instead of the module-named one. |
| `backup_storage_replication` | `"ZRS"` | Zone-redundant within the region. `GRS` adds a cross-region replica — check data-residency commitments first. |
| `backup_immutability_days` | `30` | Unlocked policy, so operators can extend. |
| `backup_blob_soft_delete_days` | `30` | Blob + container soft delete. |
| `backup_blob_noncurrent_expiration_days` | `365` | Noncurrent version expiry. |
| `enable_pre_patch_run_command` | `true` | Installs `RunPrePatchBackup`. Currently ⛔ — see Step 2. |
| `enable_post_patch_run_command` | `true` | Installs `RunPostPatchVerify` on each VM. Currently ⛔ — see Step 5. |
| `schema_version_endpoint_path` | `/api/instance/schema-version` | Exported via the `schema_version_endpoint` output. |
| `db_backup_retention_days` | `14` | Flexible Server automated-backup retention (7–35). |
| `postgres_geo_redundant_backup_enabled` | `false` | `true` replicates backups to the paired region (West Europe for North Europe). Data-residency decision. |
| `db_high_availability_mode` | `"ZoneRedundant"` | `"SameZone"` is cheaper with a lower SLA. |
| `alert_email` | `null` | Creates the Action Group and both metric alerts. **Set it before a patch window** — with `null` there is no tripwire at all. |
| `refresh_rollback_5xx_count_threshold` | `10` | App Gateway 5xx **count** over 5 min (AWS's equivalent is a percentage rate). |
| `enable_application_gateway` | `false` | Required for WAF and for real TLS termination. |
| `waf_policy_id` | `null` | Customer-supplied WAF policy; requires the App Gateway. |

---

## Audit pointers

For procurement and security reviewers verifying this page against the code:

1. **No HailBytes admin access.** `grep -rn azurerm_role_assignment modules/ha-hot-hot/azure/`
   — every `principal_id` is either `data.azurerm_client_config.current.object_id`
   (whoever ran `terraform apply`), a module-created disk-encryption-set
   identity, or a VM's system-assigned identity. No HailBytes tenant, no
   service principal, no SAS token.
2. **No phone-home from the deployment.** `grep -n custom_data modules/ha-hot-hot/azure/main.tf`
   — the app VMs' `custom_data` is a JSON blob of the customer's own Key Vault
   URI, DB FQDN and Redis host. The only outbound endpoints anything in this
   module reaches are Azure IMDS (`169.254.169.254`) and the customer's own
   Key Vault. Full image-level audit, including the browser-side telemetry that
   this repo cannot see: [`AZURE_HA_PARITY_AUDIT.md`](AZURE_HA_PARITY_AUDIT.md).
3. **Patches are customer-initiated.** `grep -rniE 'automation_schedule|maintenance_configuration|cron' modules/`
   — nothing. The Run Command resources exist but execute only on resource
   creation or on an explicit Portal/CLI invocation.
4. **No HailBytes-controlled SSH key.** `grep -n admin_ssh_key modules/ha-hot-hot/azure/main.tf`
   — `public_key = var.ssh_public_key`, a required input with no default.
   Nothing is hardcoded.

Summary of module-wide defaults: [`SECURITY-DEFAULTS.md`](../SECURITY-DEFAULTS.md)
— note that its Azure claims about flow logs, LB access logs and
`enable_management_access` do not currently hold; see the parity audit.

---

## Related

- [`PATCHING_AND_MIGRATION.md`](PATCHING_AND_MIGRATION.md) — the AWS procedure this page pairs with
- [`AZURE_HA_PARITY_AUDIT.md`](AZURE_HA_PARITY_AUDIT.md) — every Azure-vs-AWS gap, with effort estimates
- [`AZURE_COST_SHAPES.md`](../AZURE_COST_SHAPES.md) — North Europe pricing for the three shapes
- [`SECURITY-DEFAULTS.md`](../SECURITY-DEFAULTS.md) — security controls baked into all modules
- HailBytes SAT runbook (underlying mechanics): [`hailbytes-sat/docs/AWS_HA_DEPLOYMENT.md`](https://github.com/HailBytes/hailbytes-sat/blob/main/docs/AWS_HA_DEPLOYMENT.md)
- Marketplace identifiers: [`hailbytes-sat/MARKETPLACE.md`](https://github.com/HailBytes/hailbytes-sat/blob/main/MARKETPLACE.md)
