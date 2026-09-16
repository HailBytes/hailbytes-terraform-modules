# Recovering a lost Terraform state — Azure

For the case where the deployment is alive and healthy but the state file that
described it is gone: a Cloud Shell session that ended, a laptop that was
rebuilt, a `.terraform/` directory someone cleaned up.

Nothing in this page is theoretical. It is written from a customer recovery on
the Azure HA tier, where phase 1 had completed and the state was lost before
phase 2 (App Gateway + TLS) began.

> [!IMPORTANT]
> Read [Before you touch anything](#before-you-touch-anything) first. The
> deployment is not in danger; the sequence you run is what decides whether it
> stays that way.

---

## Why this happens

`quickstart/deploy.sh` runs `terraform init` with **no backend block**, so the
state lands in `$HOME/hailbytes-deploy/terraform.tfstate` on whatever machine
ran it. In Azure Cloud Shell that home directory only survives if the session
has a storage account mounted. An ephemeral Cloud Shell session discards it
when the session closes, and the deployment it created carries on running with
nothing describing it.

This is a defect in the quickstart, not operator error. See
[Preventing a repeat](#preventing-a-repeat).

## How to tell you are in this situation

```
Error: A resource with the ID "/subscriptions/.../vaults/kv-..." already
exists - to be managed via Terraform this resource needs to be imported
into the State.
```

A `terraform plan` that proposes to **create** resources you can see in the
portal is the same symptom. Importing the resource group alone does not help:
it adopts one resource and leaves every other one in the group unrepresented.

---

## Before you touch anything

Three facts change the risk calculation, and all three are in your favour.

**1. Every generated secret is already persisted.** The module writes all
non-deterministic values into Key Vault at deploy time:

| Key Vault secret | Terraform resource |
|---|---|
| `hailbytes-db-password` | `random_password.db` |
| `hailbytes-session-keys` (`<hash hex>:<enc hex>`) | `random_id.session_hash_key`, `random_id.session_enc_key` |
| `hailbytes-admin-initial-password` | `random_password.admin_initial` |
| `hailbytes-redis-access-key` | read from the cache, not generated |

So the values are recoverable. This is what makes a no-rotation recovery
possible at all.

**2. The database carries a delete lock.** `azurerm_management_lock.db` is
`CanNotDelete` whenever `db_mode = "flexible_server"` and
`enable_db_delete_lock` is on (the default). Azure refuses a delete against it
regardless of what Terraform asks for.

**3. The VMs ignore image and bootstrap drift.** The app VMs carry
`lifecycle { ignore_changes = [source_image_reference, custom_data] }`, so an
import will not fight you over a floating `marketplace_image_version` or a
regenerated `custom_data` payload.

What is genuinely worth caution: **do not run `terraform apply` from a
partially-imported state.** A plan built from incomplete state describes a
deployment that does not exist. Plans, refreshes and `state list` are all safe.

---

## Step 0: restore service first

Recovery of the state and recovery of the service are separate problems. Do
the service first so nothing downstream is running against a clock.

If the load balancer frontend has no public IP (common when someone detached a
reserved address in preparation for an App Gateway that was never created),
reattach it. The frontend is named `frontend` in every tier module:

```bash
az network lb frontend-ip update \
  --resource-group  <rg> \
  --lb-name         <name-prefix>-lb \
  --name            frontend \
  --public-ip-address <public-ip-resource-id>
```

Confirm the pool is healthy before moving on:

```bash
az network lb show -g <rg> -n <name-prefix>-lb \
  --query 'frontendIPConfigurations[0].publicIPAddress.id' -o tsv
curl -sk -o /dev/null -w '%{http_code}\n' https://<address>/api/health
```

A `curl` from Cloud Shell will time out even when everything is correct: Azure
Standard Load Balancer does not SNAT inbound load-balanced traffic, so the NSG
evaluates the original client IP and Cloud Shell's egress address is not in
`allowed_cidrs`. Test from inside the allow-list.

---

## Choosing a path

| | Rebuild clean | Import into fresh state |
|---|---|---|
| Effort | one apply, ~40 min | ~75 imports, half a day |
| Outcome | fully-known state, remote backend from the start | state matching a deployment nobody has re-verified |
| Data | needs `pg_dump`/`pg_restore` if any exists | preserved in place |
| Failure mode | a name collision (see below) | a silent mismatch that surfaces on a later apply |

**Rebuild is the default recommendation.** The import path adopts ~75
resources into a state file whose correctness you cannot prove until a much
later apply, and it buys you a deployment you were about to change anyway.

Import is the right call when the deployment carries data or configuration
that cost real work to produce, and even then, weigh `pg_dump` into a fresh
stack first — it is almost always less work than 75 imports.

---

## Path A: rebuild clean

### A1. Protect what must survive

The reserved public IP is the thing DNS points at. If it lives in the resource
group you are about to delete, move it out first:

```bash
az resource move \
  --destination-group  <permanent-rg> \
  --ids                <public-ip-resource-id>
```

Give it a delete lock once moved:

```bash
az lock create --name pin-ingress-ip --lock-type CanNotDelete \
  --resource-group <permanent-rg> \
  --resource-name <pip-name> --resource-type Microsoft.Network/publicIPAddresses
```

If the database holds anything worth keeping:

```bash
pg_dump "host=<server>.postgres.database.azure.com user=hailbytes \
  dbname=hailbytes sslmode=require" -Fc -f hailbytes.dump
```

### A2. Stand up remote state before the first apply

This is the step whose absence caused the incident. Do it first, every time.

```bash
az group create -n tfstate-rg -l northeurope
az storage account create -n <globally-unique> -g tfstate-rg -l northeurope \
  --sku Standard_LRS --encryption-services blob --min-tls-version TLS1_2 \
  --allow-blob-public-access false
az storage container create -n tfstate --account-name <globally-unique>
az lock create --name protect-tfstate --lock-type CanNotDelete \
  --resource-group tfstate-rg
```

Then, in the root module:

```hcl
terraform {
  backend "azurerm" {
    resource_group_name  = "tfstate-rg"
    storage_account_name = "<globally-unique>"
    container_name       = "tfstate"
    key                  = "hailbytes-sat-prod.tfstate"
    use_azuread_auth     = true
  }
}
```

Blob storage gives you state locking via blob lease, and versioning on the
container gives you a rollback if a state write goes wrong. Both are worth
turning on.

### A3. Pick a new Key Vault name

The module sets `purge_protection_enabled = true` and
`soft_delete_retention_days = 30`. A deleted vault holds its name for 30 days
and **cannot be purged early** while purge protection is on. So a rebuild
needs a name the old vault is not sitting on:

```hcl
key_vault_name = "kv-<something>-<short random suffix>"
```

Also set `recover_soft_deleted_key_vaults = false` in the provider `features`
block — see the comment in `quickstart/azure-ha-byoip/main.tf` for the RBAC
scope failure it avoids.

### A4. Apply, then tear down the old group

Remove the database lock before deleting the old resource group, or the delete
fails partway and leaves debris:

```bash
az lock delete --name <name-prefix>-pg-no-delete \
  --resource-group <old-rg> \
  --resource-name <name-prefix>-pg \
  --resource-type Microsoft.DBforPostgreSQL/flexibleServers \
  --namespace Microsoft.DBforPostgreSQL
```

`quickstart/sweep-azure.sh show <rg>` inventories what is in the group, and
`sweep-azure.sh delete <rg>` removes it behind a typed confirmation and a
hostname guard. Do not delete the old group until the new one serves traffic.

---

## Path B: import into fresh state

### B1. Enumerate

```bash
./quickstart/sweep-azure.sh imports <rg> --module module.<yours>.module.this
```

This prints commands rather than running them, by design: an import writes
ownership into state, and an import of something whose settings do not match
your configuration means the next apply mutates it.

The script does not yet cover every resource the tier module creates. For the
remainder:

```bash
az resource list -g <rg> --query '[].[type,name,id]' -o tsv
```

Microsoft's `aztfexport` will also enumerate a resource group and emit import
blocks. Its addresses are flat rather than module-shaped, so treat its output
as an inventory to remap, not as configuration to adopt.

### B2. Import the generated values from Key Vault

Do this **before** the first apply. Skip it and Terraform generates fresh
values and rotates them on apply.

```bash
KV=<vault-name>
DB_PW=$(az keyvault secret show --vault-name "$KV" \
  -n hailbytes-db-password --query value -o tsv)
ADMIN_PW=$(az keyvault secret show --vault-name "$KV" \
  -n hailbytes-admin-initial-password --query value -o tsv)
SESSION=$(az keyvault secret show --vault-name "$KV" \
  -n hailbytes-session-keys --query value -o tsv)

terraform import 'module.<yours>.module.this.random_password.db' "$DB_PW"
terraform import 'module.<yours>.module.this.random_password.admin_initial' "$ADMIN_PW"
```

The two session keys are stored hex and `random_id` imports base64url, so
convert:

```bash
hex2b64url() { printf '%s' "$1" | xxd -r -p | base64 | tr '+/' '-_' | tr -d '=' ; }
terraform import 'module.<yours>.module.this.random_id.session_hash_key' \
  "$(hex2b64url "${SESSION%%:*}")"
terraform import 'module.<yours>.module.this.random_id.session_enc_key' \
  "$(hex2b64url "${SESSION##*:}")"
```

> [!WARNING]
> The `random` provider's importers do not reconstruct every argument from the
> ID, so an imported `random_password` can still plan a replacement against a
> configuration that sets `special = false` or a specific `length`. **Check
> `terraform plan` before trusting this.** If the `random_*` resources still
> plan a replacement, accept the rotation rather than fighting it — see
> [If values rotate anyway](#if-values-rotate-anyway).

### B3. Plan until it is a no-op

The finish line is a plan reporting **no changes**. Until then you are not
done, and an apply is not safe. Work the diff down one resource at a time,
fixing the *configuration* to match reality rather than importing harder.

Resources that commonly still differ:

- `expiration_date` on the three Key Vault secrets — covered by
  `ignore_changes`, so it should settle on a second plan.
- `db_high_availability_mode` — if HA was disabled at deploy time because of a
  subscription entitlement, the variable must say `"Disabled"` or the plan
  proposes to add a standby.
- `marketplace_image_version` — floats on `"latest"`, but `ignore_changes` on
  `source_image_reference` means it should not surface.

### If values rotate anyway

If the plan insists on regenerating the `random_*` resources, the outcome is
survivable and non-destructive, but know what it costs:

- **DB password.** Terraform updates the Postgres server *and* the Key Vault
  secret in the same apply, so the two stay consistent. The VMs read the
  secret at boot only (`custom_data` carries the secret *name*, not its value),
  so each node needs a restart to pick up the new password. Restart them one
  at a time to keep the pair serving.
- **Session keys.** Every logged-in user is signed out. No data loss.
- **Initial admin password.** The Key Vault secret changes but the admin user
  already exists in the database, so the new value is simply stale. Harmless.

None of these touch campaign, target or result data.

---

## Preventing a repeat

1. **Never run a production apply from Cloud Shell without a remote backend.**
   The quickstart should configure one before the first apply; until it does,
   do step [A2](#a2-stand-up-remote-state-before-the-first-apply) by hand.
2. **Commit the root module and its `.tfvars`** (secrets excluded) somewhere
   durable. `deploy.sh` writes a `.gitignore` covering `secrets.auto.tfvars`,
   `.terraform/` and `*.tfstate*` precisely so the rest can be committed.
3. **Back up state before a phase-2 change.** `terraform state pull >
   state-$(date +%F).json` costs nothing.

---

## A SAT-specific trap in the same territory

The recovery above often runs alongside an App Gateway rollout, so it is worth
stating plainly:

**On SAT the load balancer frontend must stay public.** The App Gateway does
not sit in front of the load balancer; the two are parallel entry points. The
gateway declares one listener on 443 routing to the admin console, and it has
no port-80 path to the phishing server. The load balancer carries both `443 ->
admin_port` and `80 -> phish_port` on a single frontend, so taking that
frontend internal removes the landing pages from the internet, which on SAT is
the product's core function.

The module enforces this: `lb_frontend_public = false` fails a precondition
when `product = "sat"`.

The practical consequence for anyone moving a reserved address onto a gateway:
**SAT needs two public addresses and two hostnames.** One on the gateway for
the admin console, one on the load balancer for the landing pages. Decide
which hostname goes where before the phase-2 apply, because
`terraform output dns_target` changes between phases and DNS has to follow it.

To bound public access to the console, use `allowed_cidrs`, which applies to
the gateway and the load balancer alike. The phishing surface has its own
allow-list in `phish_allowed_cidrs`.

---

## See also

- [`AZURE_PATCHING_AND_MIGRATION.md`](AZURE_PATCHING_AND_MIGRATION.md) — rolling replace, pre-patch backups
- [`../quickstart/azure-ha-byoip/README.md`](../quickstart/azure-ha-byoip/README.md) — the two-phase gateway rollout
- [`../quickstart/sweep-azure.sh`](../quickstart/sweep-azure.sh) — inventory, import printing, guarded deletes
