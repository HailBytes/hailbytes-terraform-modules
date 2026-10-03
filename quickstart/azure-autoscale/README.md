# Quickstart: HailBytes SAT on Azure, autoscale tier

A VM scale set of HailBytes SAT instances, spread across Availability Zones 1-3
behind a load balancer, with a Postgres Flexible Server, Azure Cache for Redis
for shared sessions, and Key Vault. Like [`azure-ha`](../azure-ha), this config
also creates the networking, so you need only two inputs.

Use it for one shared instance carrying many clients, or one very large client.
For most single clients the [HA tier](../azure-ha) is the better fit.

Everything deploys into **your** subscription. No HailBytes access, no
phone-home. Software billing runs through your Azure Marketplace subscription
at $0.24/vCPU-hour **per running instance**. `vmss_max_count` caps the
software bill as well as capacity.

Running this for an MSSP client? Follow
[docs/AZURE_MSSP_RUNBOOK.md](../../docs/AZURE_MSSP_RUNBOOK.md). It covers the
same steps for every tier, plus per-client state and teardown.

## Step 1: Subscribe and run the preflight

Subscribe to [HailBytes SAT](https://marketplace.microsoft.com/en-us/product/virtual-machines/lcmcon1687976613543.gophish-phishing-simulator?tab=overview)
on Azure Marketplace, then check the subscription. Size the quota check for the
ceiling, not the floor:

```bash
git clone https://github.com/hailbytes/hailbytes-terraform-modules
cd hailbytes-terraform-modules/quickstart/azure-autoscale
../preflight-azure.sh autoscale --location northeurope --max-count 4
```

## Step 2: Configure and apply

```bash
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: set allowed_cidrs, ssh_public_key, and usually phish_allowed_cidrs
../bootstrap-state-azure.sh --out . --location northeurope --key hailbytes-sat-autoscale.tfstate
terraform init && terraform apply
```

What this root sets differently from the module defaults, and why:

| Input | Here | Module default | Why |
|---|---|---|---|
| `vm_size` | `Standard_D2s_v3` | `Standard_D4s_v5` | Same size as the HA tier. Draws the DSv3 quota pool, not DSv5, which is often granted 0 on a new subscription. |
| `vmss_max_count` | `4` | `20` | Every instance meters. Raise it when measured load needs it. |
| `db_replica_count` | `0` | `2` | Each replica is a full database server. Add them when read load calls for it. |
| `key_vault_name_random_suffix` | `true` | `false` | Vault names are global and reserved for 30 days after a destroy. |

Redis stays on. On this tier it is the only shared session store.

## Step 3: Verify

```bash
curl -k https://$(terraform output -raw load_balancer_public_ip)/api/health
VAULT=$(terraform output -raw key_vault_uri | sed -E 's#https://([^.]+)\..*#\1#')
../keyvault-maintenance.sh get --vault "$VAULT" --secret hailbytes-admin-initial-password
```

Log in as `admin` with that password and change it.

## Tearing down

```bash
terraform plan -destroy -out destroy.tfplan   # read it: everything should be in one resource group
terraform apply destroy.tfplan
```

[Runbook Step 10](../../docs/AZURE_MSSP_RUNBOOK.md#step-10-tear-it-down-with-terraform)
covers exporting data first, lifting delete locks, keeping other deployments'
Marketplace terms intact, and what deliberately survives.
