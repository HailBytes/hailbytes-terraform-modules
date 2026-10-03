# HailBytes SAT on Azure: the MSSP runbook

Stand up HailBytes SAT for a client on Azure, run it, and tear it down again,
with Terraform, one numbered step at a time. Every command is copy-paste. Each
step says what it does, what to check before moving on, and what to do when it
goes wrong.

It is written from the first customer deployments of these modules. Every
failure those hit is either prevented by the steps below or named in
[What the first deployments taught us](#what-the-first-deployments-taught-us),
so you meet it here instead of halfway through an apply.

> One deployment per client. Each client gets its own resource group, its own
> Key Vault, its own database and its own Terraform state, so tearing one
> down cannot touch another. If you would rather run several clients on one
> shared instance, that is a product decision (branding and SSO are
> instance-wide), covered on
> [hailbytes.com/for-mssps](https://hailbytes.com/for-mssps/#topologies). The
> steps below are the same either way. A shared instance is one deployment
> with your own name as `customer`.

---

## Before you start: two decisions

### Decision 1. Whose subscription?

| | **A. Your subscription** | **B. The client's subscription** |
|---|---|---|
| Who pays Azure | You, then you re-bill | The client, directly |
| Who runs `terraform apply` | You | You or the client, usually as a service principal the client owns |
| Marketplace terms | Accepted **once** for your subscription (Step 2) | Accepted once for theirs (Step 2) |
| Terraform state | One state account for all your clients, one state file per client (Step 4) | A state account in their subscription |
| Who can read the database password | Whoever ran the apply, plus anyone in `key_vault_reader_principal_ids` | Same, which matters more here: see Step 5 |
| Data residency evidence | Your subscription's Activity Log | The client's own Activity Log |

Both use exactly the same steps. Where a step differs, it says **(A)** or **(B)**.

### Decision 2. Which tier?

| Tier | Quickstart | Application nodes | Database | Use when |
|---|---|---|---|---|
| Single VM | [`quickstart/azure-single`](../quickstart/azure-single) | 1 | PostgreSQL on the VM | Pilots, small clients. A reboot is an outage and the VM holds the only copy of the data. |
| HA hot-hot | [`quickstart/azure-ha`](../quickstart/azure-ha) | 2, across zones 1 and 2 | Flexible Server, zone-redundant standby | Production for most clients. |
| HA with a reserved IP and TLS | [`quickstart/azure-ha-byoip`](../quickstart/azure-ha-byoip) | 2 | Flexible Server | Production where the client owns DNS and wants a fixed address and a trusted certificate from day one. |
| Autoscale | [`quickstart/azure-autoscale`](../quickstart/azure-autoscale) | 2 to `vmss_max_count`, across zones 1-3 | Flexible Server, plus optional read replicas | One shared instance carrying many clients, or one very large client. |

The software meter is $0.24 per vCPU-hour on every node running the HailBytes
image, billed through the client's or your Marketplace subscription. The Azure
infrastructure (VMs, database, load balancer, storage) is billed separately by
Microsoft on the same subscription. [`AZURE_COST_SHAPES.md`](../AZURE_COST_SHAPES.md)
has both, side by side.

Set three shell variables for the rest of the runbook. Everything below reads them:

```bash
export CUSTOMER=acme          # 2-16 chars: lowercase letters, digits, hyphens
export TIER=ha                # single | ha | autoscale
export LOCATION=northeurope   # the client's region
```

---

## Step 1. Sign in, and point at the right subscription

Use [Azure Cloud Shell](https://shell.azure.com) (bash). It already has `az`,
`terraform` and `git`. A workstation works too with Terraform 1.5 or newer.

**(A) or (B) as a person:**

```bash
az login                                  # not needed in Cloud Shell
az account set --subscription "<subscription name or id>"
az account show --query '{name:name, id:id}' -o table
```

**(B) as the client's service principal.** Terraform reads these four
variables directly. Nothing is stored and HailBytes never sees them:

```bash
export ARM_CLIENT_ID=<appId> ARM_CLIENT_SECRET=<secret> \
       ARM_TENANT_ID=<tenantId> ARM_SUBSCRIPTION_ID=<subscriptionId>
az login --service-principal -u "$ARM_CLIENT_ID" -p "$ARM_CLIENT_SECRET" --tenant "$ARM_TENANT_ID"
```

The identity needs **Owner** on the subscription, or Contributor plus User
Access Administrator. The deployment creates role assignments (Key Vault
access, the VMs' managed identities) and plain Contributor cannot.

**Check before moving on:** `az account show` names the subscription you mean.
Everything after this lands in it.

## Step 2. Subscription prep: once per subscription, not per client

1. Open the [HailBytes SAT Marketplace listing](https://marketplace.microsoft.com/en-us/product/virtual-machines/lcmcon1687976613543.gophish-phishing-simulator)
   while signed in to this subscription, and make sure it is purchasable.
2. Run the preflight. It registers the resource providers the stack needs,
   accepts the Marketplace image terms, and checks the three regional things
   that otherwise fail an apply twelve minutes in: the image is published in
   the region, the availability zones exist for the VM size, and there is vCPU
   quota for it.

```bash
git clone --depth 1 https://github.com/HailBytes/hailbytes-terraform-modules ~/hailbytes-terraform-modules
~/hailbytes-terraform-modules/quickstart/preflight-azure.sh "$TIER" --location "$LOCATION" --accept-terms
# autoscale: add --max-count <ceiling>. Any tier: add --vm-size <size> if you will set vm_size.
# The defaults it checks are the sizes each quickstart deploys: Standard_D2s_v3
# for HA and autoscale, Standard_D4s_v5 for single VM.
```

**Why the terms are accepted here and not by Terraform.** Image terms belong to
the *subscription*. If a client's Terraform accepts them, that client's state
owns them, and two things follow. The next client's apply fails with
`already exists`. And destroying the first client **cancels the terms for every
other deployment in the subscription**, which breaks their image swaps and
scale-out. Setting `customer` (Step 5) switches Terraform's acceptance off for
exactly this reason.

**Check before moving on:** read the preflight output, not just its exit code.
It reports rather than fails, so a `WARNING` (a zone missing for the size), a
`NOT ENOUGH` (quota), or an image not visible in the region all still end the
run normally. Each one fails the apply later. Quota needs an increase request
(Subscription > Usage + quotas), which Terraform cannot make and Azure does not
approve instantly.

**One thing preflight cannot see:** whether Azure will let this subscription
create a *zone-redundant* Postgres in this region. That is granted per
subscription and per region, and the HA apply tells you if it is not
(`MultiAzHaIsOfferRestricted`). File the request early. Starting without the
standby and adding it in place later is covered in
[AZURE_POSTGRES_ZONE_REDUNDANT_HA.md](AZURE_POSTGRES_ZONE_REDUNDANT_HA.md).

## Step 3. Give the client their own working directory

A working directory holds that client's settings, state pointer and provider
cache. Never share one between clients.

```bash
git clone --depth 1 https://github.com/HailBytes/hailbytes-terraform-modules ~/hailbytes/"$CUSTOMER"
cd ~/hailbytes/"$CUSTOMER"/quickstart/azure-"$TIER"
```

Keep the directory, or at least its `terraform.tfvars` and `backend.tf`, in
your own version control. Step 10 needs them.

## Step 4. Durable Terraform state

State in Cloud Shell's home directory does not survive an ephemeral session.
Lose it and the deployment keeps running with nothing describing it, which is
recoverable ([AZURE_STATE_RECOVERY.md](AZURE_STATE_RECOVERY.md)) but slow.

**First client in this subscription.** This creates a locked-down state account
(Entra auth only, versioned, delete-locked) and writes `backend.tf`:

```bash
../bootstrap-state-azure.sh --out . --location "$LOCATION" --key "clients/$CUSTOMER/sat-$TIER.tfstate"
```

It prints the account name it created. Note it down.

**Every later client in the same subscription.** Reuse that account. Only the key changes:

```bash
../bootstrap-state-azure.sh --out . --location "$LOCATION" \
  --account <account name from the first client> --key "clients/$CUSTOMER/sat-$TIER.tfstate"
```

**Check before moving on:** `backend.tf` exists in this directory and names
`clients/<customer>/...` as its key.

## Step 5. Fill in terraform.tfvars

```bash
cp terraform.tfvars.example terraform.tfvars
```

Then set, at minimum:

```hcl
customer      = "acme"                    # same as $CUSTOMER. Set it now: changing it later replaces everything
location      = "northeurope"
allowed_cidrs = ["203.0.113.0/24"]        # who may reach the ADMIN console: your SOC, the client's admins
ssh_public_key = "ssh-ed25519 AAAA... you@host"

# Who may reach the PHISHING landing pages. These are the simulation targets,
# who are by definition not in the admin range. Leave it unset and the campaign
# sends, then records no clicks, which looks like a product fault.
phish_allowed_cidrs = ["0.0.0.0/0"]
```

What `customer` does:

- Prefixes every resource with `<customer>-sat-<environment>` and puts it all in
  `rg-<customer>-sat-<environment>`. Postgres server and storage account names
  are **globally** unique, so two clients on the default names collide.
- Tags every resource `customer=<customer>`. Filter Azure Cost Management by
  that tag to get each client's infrastructure bill.
- Turns off Terraform's acceptance of the Marketplace terms (Step 2 did it
  once for the subscription).

**HA tier, and especially (B):** whoever runs the apply is granted access to
the Key Vault holding the database password and session keys, and nobody else
is. If that is a service principal, your operators are locked out of their own
deployment. Grant a group at deploy time:

```hcl
key_vault_reader_principal_ids = ["<Entra group object id>"]
```

**HA with a reserved IP (`azure-ha-byoip`):** that root has no `customer`
input. Set `name_prefix = "<customer>-sat"` and
`resource_group_name = "rg-<customer>-sat-prod"` yourself, and
`accept_marketplace_terms = false`, because Step 2 already accepted the terms.

**Autoscale:** also review `vm_size`, `vmss_min_count`, `vmss_max_count` and
`db_replica_count` in the example. Every running instance meters, so
`vmss_max_count` is the ceiling on the software bill.

**Client has a host-naming standard?** `vm_names` (HA) takes the exact VM names
in zone order. Set it before the first apply. Renaming a VM later replaces it.

## Step 6. Plan, read the plan, apply

```bash
terraform init
terraform plan -out tfplan
```

Read the plan before applying it. Check that every resource is in
`rg-<customer>-...`, and that nothing is planned for **destroy** on a first
apply. Then:

```bash
terraform apply tfplan 2>&1 | tee apply.log
```

**If it fails,** do not re-run blindly and do not change names to get past it:

```bash
../explain.sh apply.log
```

It names the cause, who can fix it (you, or a subscription admin), and the
exact command. Where an admin is needed it prints a paragraph you can forward
as is. Re-running the same apply after the fix is safe. Terraform picks up
where it stopped.

**On HA, read the warnings too.** If the database came up without its standby
(`database_has_a_standby`), the plan and apply both say so. The deployment
works, but a zone outage takes the database with it. Don't tell the client
it's HA until the standby is in place (Step 2, last paragraph).

## Step 7. Verify, and log in for the first time

```bash
IP=$(terraform output -raw load_balancer_public_ip 2>/dev/null || terraform output -raw public_ip_address)
curl -k "https://$IP/api/health"          # expect HTTP 200. /health (no /api) is a 404 by design
```

The first-boot admin password:

- **Single VM:** `eval "$(terraform output -raw initial_credentials_command)"`
- **HA and autoscale:** it is in the deployment's Key Vault.

  ```bash
  VAULT=$(terraform output -raw key_vault_uri | sed -E 's#https://([^.]+)\..*#\1#')
  ../keyvault-maintenance.sh get --vault "$VAULT" --secret hailbytes-admin-initial-password
  ```

Browse to `https://<IP>/`, log in as `admin`, and change the password. The
certificate is self-signed until Step 8, so expect a browser warning.

**HA only, optional:** prove failover before the client relies on it. Stop one
node, confirm `/api/health` still answers, then start it again:

```bash
RG=$(terraform output -raw resource_group_name)
VM=$(terraform output -json vm_ids | jq -r '.[0] | split("/")[-1]')
az vm deallocate -g "$RG" -n "$VM" && curl -k "https://$IP/api/health" && az vm start -g "$RG" -n "$VM"
```

## Step 8. DNS, a trusted certificate, and mail delivery

**DNS.** The load-balancer address is static for the life of the deployment.
Point the console hostname's A record at it. If the hostname has to survive a
rebuild, or the client wants DNS in place *before* deploying, reserve the
address in a resource group the deployment does not own and hand it in. That
is [`quickstart/azure-ha-byoip`](../quickstart/azure-ha-byoip). Azure has
no undelete for a public IP, so an address created inside the deployment's
resource group is gone for good when that group is destroyed.

**TLS.** For a trusted certificate, put an Application Gateway in front with the
client's PFX (`enable_application_gateway`; walkthrough in
[`azure-ha-byoip/README.md`](../quickstart/azure-ha-byoip/README.md) and
[TLS termination](../modules/ha-hot-hot/azure/README.md#tls-termination)).
Three things the first deployments learned:

- The gateway subnet does **not** need to be a /24. That is Microsoft's
  recommendation. With this module's 10-instance cap a /27 is comfortable. A
  /28 technically fits but leaves no room for Azure's maintenance upgrades.
- On SAT the gateway carries the **console** only. The phishing landing pages
  stay on the load balancer's address. That makes two hostnames, so don't
  free the load balancer's address for the gateway.
- Prefer the client's own certificate over Let's Encrypt on HA. The HTTP-01
  challenge through a layer-4 load balancer lands on either node at random.

**Mail delivery.** Simulations land only if the client's mail filtering lets
them. [`quickstart/allowlisting`](../quickstart/allowlisting) scripts the
Exchange Online side.
[`DELIVERABILITY_CHECKLIST.md`](DELIVERABILITY_CHECKLIST.md) covers the rest.
Third-party filtering gateways often accept an allow-list request only from
their customer, so ask the client to raise it in week one. This is the failure
mode where everything deploys correctly and no simulation arrives.

## Step 9. Hand over and operate

- **Key Vault access.** If you skipped `key_vault_reader_principal_ids`,
  [`keyvault-maintenance.sh`](../quickstart/keyvault-maintenance.sh) `grant`
  adds a person or group now. `rotate-session-keys` rotates the shared session
  keys.
- **Patching.** HailBytes publishes new images to the Marketplace. You, or the
  client, decide when to roll them. See
  [AZURE_PATCHING_AND_MIGRATION.md](AZURE_PATCHING_AND_MIGRATION.md).
- **Production safety (HA roots).** Once the client is live, consider
  `enable_db_delete_lock = true` and `enable_public_ip_delete_lock = true` in
  `terraform.tfvars`.
  Both block deletion by anyone, `terraform destroy` included, which is the
  point. Step 10 shows how to lift them.
- **Per-client cost.** Filter Cost Management by tag `customer = <customer>`.
- **Record keeping.** Keep the working directory from Step 3. Its `backend.tf`
  is the only pointer to this client's state.

## Step 10. Tear it down with Terraform

Run this from the client's working directory (Step 3), signed in to the same
subscription (Step 1).

**1. Take what you need first.** Destroy deletes the database. Note the
resource group too, because the outputs go with the stack.

```bash
RG=$(terraform output -raw resource_group_name)
IP=$(terraform output -raw load_balancer_public_ip 2>/dev/null || terraform output -raw public_ip_address)
# Full export (database dump + uploads) with an admin's API key from Settings:
curl -kf -H "Authorization: Bearer <admin API key>" "https://$IP/api/instance/export" -o "$CUSTOMER-export.tar.gz"
```

**2. Lift any delete locks in their own apply.** A lock makes destroy fail
partway, leaving a half-deleted stack.

```bash
# HA roots only; the single-VM and autoscale roots have no locks to lift.
terraform apply -var enable_db_delete_lock=false -var enable_public_ip_delete_lock=false
```

**3. Read the destroy plan.**

```bash
terraform plan -destroy -out destroy.tfplan
terraform show destroy.tfplan | grep -E '^\s+# .* will be destroyed'
```

Everything listed should be inside `rg-<customer>-...`. Look for
**`azurerm_marketplace_agreement`** in particular. With `customer` set it is
not there. If it *is* there (a deployment created before `customer` existed,
or with `accept_marketplace_terms = true`) and anything else in the
subscription runs the HailBytes image, take it out of state first so the
destroy does not cancel the terms for everyone:

```bash
terraform state list | grep azurerm_marketplace_agreement
terraform state rm '<the address it printed>'
terraform plan -destroy -out destroy.tfplan
```

**4. Destroy.**

```bash
terraform apply destroy.tfplan 2>&1 | tee destroy.log
```

If it stops partway, run the same two commands again. Destroy is idempotent and
picks up where it stopped. If it fails the same way twice, run
`../explain.sh destroy.log`.

**5. Confirm nothing is left billing.**

```bash
az group exists -n "$RG"                                         # expect: false
../sweep-azure.sh list --prefix "$CUSTOMER-sat-"                  # expect: nothing
```

`sweep-azure.sh` is also the fallback when state is gone or a group is
half-deleted. `show <rg>` lists what is inside, including the child resources
`az resource list` misses, and `delete <rg>` removes it with guard rails.

**6. Clean up the state file**, once you are sure the client is not coming back:

```bash
az storage blob delete --auth-mode login --account-name <state account> \
  --container-name tfstate --name "clients/$CUSTOMER/sat-$TIER.tfstate"
```

Leave the state account itself alone. Your other clients' state lives in it,
and it carries a delete lock for that reason.

### What deliberately survives a destroy

| What | Why | What to do |
|---|---|---|
| The Key Vault's **name** | Purge protection (required by disk encryption) reserves a deleted vault's name for 30 days, with no force-purge | Nothing. The quickstarts draw a fresh random suffix on every new deployment, so rebuilding the same client inside 30 days just works. |
| An IP you **reserved yourself** (byoip) | It lives in your resource group, not the deployment's | Keep it for the rebuild, or delete it when DNS no longer points at it. |
| The Marketplace **terms** | Accepted per subscription in Step 2, not owned by any one client | Leave them. Other clients depend on them. |
| The **state account** | Shared by every client in the subscription | Delete only the client's blob (point 6). |

---

## What the first deployments taught us

Every row but the last is something a customer deployment actually ran into,
with what now handles it. If you hit something that isn't here, `explain.sh` is
the place to add it.

| What happened | Where it is handled |
|---|---|
| VM create failed 12 minutes in: `standardDSv5Family` quota was 0 on a subscription that had never asked for it | Default size is now `Standard_D2s_v3`. The preflight checks the quota pool for whatever size you set (Step 2). |
| `SoftDeletedVaultDoesNotExist` on a brand-new vault. The real cause was resource-group-scoped RBAC, or a name a previous attempt had spent | `recover_soft_deleted_key_vaults = false` and a random vault-name suffix in every quickstart. `explain.sh` names the real cause. |
| Postgres came up without its zone-redundant standby (`MultiAzHaIsOfferRestricted`) while the client believed they had HA | A warning on every plan and apply until the standby exists. [AZURE_POSTGRES_ZONE_REDUNDANT_HA.md](AZURE_POSTGRES_ZONE_REDUNDANT_HA.md) covers the request. |
| Terraform state vanished with a Cloud Shell session between two phases of a rollout | Remote state before the first apply (Step 4) |
| A reserved public IP was deleted along with a failed attempt's resource group, and DNS had to move | Reserve it outside the deployment (byoip), or `enable_public_ip_delete_lock` |
| Enabling the Application Gateway put the admin console on the internet, because the gateway subnet had no NSG | The gateway subnet now gets an NSG bounded by `allowed_cidrs` |
| Admin console locked down correctly, and the simulation targets then could not reach the landing pages | Separate `phish_allowed_cidrs` (Step 5) |
| The apply ran as a service principal, so no human could read the database password | `key_vault_reader_principal_ids` and `keyvault-maintenance.sh` (Steps 5 and 9) |
| The client's naming standard did not match generated VM names | `vm_names` / `db_vm_name` |
| A third-party mail gateway would take an allow-list request only from its own customer | Called out in Step 8 so it starts in week one |
| *(Not yet hit; found while writing this runbook)* A second client in the same subscription would fail on already-accepted Marketplace terms, and destroying either would cancel the other's | `customer` turns Terraform's acceptance off. Terms are accepted once per subscription (Step 2). |
