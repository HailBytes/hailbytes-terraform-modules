# Quickstart: HailBytes SAT on Azure, single-VM tier

One VM with PostgreSQL on board, its own public IP, and no load balancer. This
is the fallback when the HA tier is not warranted or not yet available.

Everything deploys into **your** subscription. No HailBytes access, no
phone-home. Software billing runs through your Azure Marketplace subscription.

## What you give up versus the HA tier

Worth being explicit, because the difference is not subtle:

| | Single-VM | HA hot-hot |
|---|---|---|
| Application nodes | 1 | 2, active/active across zones |
| Database | PostgreSQL **on the VM** | Flexible Server, zone-redundant |
| Reboot / patch | An outage | Rolling, no outage |
| VM loss | Campaign history lost unless backed up | Survivor keeps serving |
| Public surface | Public IP **on the VM** | Load balancer only; VMs have no public IP |

The single copy of your campaign history lives on that VM's data disk. Take
backups before you rely on it.

## Step 1: Subscribe on Azure Marketplace

Subscribe to [HailBytes SAT](https://marketplace.microsoft.com/en-us/product/virtual-machines/lcmcon1687976613543.gophish-phishing-simulator?tab=overview).
This is the only purchase step; the Terraform module accepts the image terms
during apply.

## Step 2: Prepare the subscription (once)

```bash
./quickstart/preflight-azure.sh single
```

Registers the resource providers this tier creates resources under, checks the
marketplace terms, and reports the RBAC the deploying identity needs. Idempotent.

Skipping this is the most common cause of a failed first apply: `main.tf` sets
`resource_provider_registrations = "none"` deliberately, so an unregistered
provider surfaces mid-apply as `API version ... was not found for Microsoft.X`,
which points at the API version rather than at the cause.

The single-VM tier needs fewer providers than HA — no `Microsoft.DBforPostgreSQL`
and no `Microsoft.Cache`, since the database is local and there is no cache.

## Step 3 (option A): Azure Cloud Shell, one command

Open [shell.azure.com](https://shell.azure.com) (bash) and run:

```bash
curl -fsSL https://raw.githubusercontent.com/hailbytes/hailbytes-terraform-modules/main/quickstart/azure-single/cloudshell.sh | bash
```

It detects your egress IP for admin-UI allow-listing, generates an SSH key if
you have none, writes `terraform.tfvars`, runs the preflight, then
`terraform init && terraform apply`. You review and confirm the plan before
anything is created. Override with `HB_RESOURCE_GROUP`, `HB_LOCATION`,
`HB_ALLOWED_CIDR`, `HB_SSH_KEY_FILE`.

## Step 3 (option B): your own workstation

Requires Terraform >= 1.5 and an authenticated Azure CLI (`az login`).

```bash
git clone https://github.com/hailbytes/hailbytes-terraform-modules
cd hailbytes-terraform-modules/quickstart/azure-single
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: set allowed_cidrs and ssh_public_key
../preflight-azure.sh single
terraform init && terraform apply
```

## Step 4: Get in

```bash
# Admin UI (self-signed certificate on first boot, so your browser will warn)
terraform output -raw console_url

# Health endpoint. SAT's path is /api/health -- there is no /health, and
# curling it returns 404, which looks like a failed deployment.
curl -k "$(terraform output -raw console_url)/api/health"

# Initial admin password, read from inside the VM
eval "$(terraform output -raw initial_credentials_command)"
```

Change the admin password at first login, then delete the credentials file.

## Moving to HA later

There is no in-place upgrade path. The HA tier provisions a separate managed
database, so moving means standing up `quickstart/azure-ha` and migrating data
across. Plan for that rather than assuming a flag flip.

## Production notes

- **Public IP on the VM.** Unlike the HA tier, this exposes the VM directly, so
  `allowed_cidrs` is the only thing in front of the admin UI. Never `0.0.0.0/0`.
- **Sizing.** Below 8 vCPUs the product's own sizing advisory reports "upsize"
  for training workloads and says so on screen, so smaller SKUs are suitable for
  phishing simulation only.
- **Costs and the three shapes side by side:** [COST_SHAPES.md](../../COST_SHAPES.md).
- **Full input reference:** [modules/single-vm/azure](../../modules/single-vm/azure/README.md).
