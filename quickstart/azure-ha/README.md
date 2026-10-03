# Quickstart: HailBytes SAT on Azure, HA tier

Zero-to-running HailBytes SAT in one `terraform apply`: two VMs active/active across Availability Zones behind a load balancer, a zone-redundant Postgres Flexible Server, and Key Vault holding the database password and the session keys both nodes share. Unlike the workload modules (which expect you to bring a vnet), this config also creates all networking prerequisites for you.

Everything deploys into **your** subscription. No HailBytes access, no phone-home. Software billing runs through your Azure Marketplace subscription at $0.24/vCPU-hr.

Running this for an MSSP client, or for more than one organisation in a
subscription? Follow [docs/AZURE_MSSP_RUNBOOK.md](../../docs/AZURE_MSSP_RUNBOOK.md).
It covers the same steps for every tier, plus per-client naming, state and
teardown.

## Step 1: Subscribe on Azure Marketplace

Subscribe to [HailBytes SAT](https://marketplace.microsoft.com/en-us/product/virtual-machines/lcmcon1687976613543.gophish-phishing-simulator?tab=overview) (Security Awareness Training / phishing simulation). This is the only purchase step; the Terraform module accepts the image terms automatically during apply.

Deploying [HailBytes ASM](https://marketplace.microsoft.com/en-us/product/virtual-machines/lcmcon1687976613543.hardened_ubuntu_with_rengine) instead? Subscribe to the ASM listing and swap the module source in `main.tf` from `sat-azure-ha` to `asm-azure-ha`.

## Step 2 (option A): Azure Cloud Shell, one command

Open [shell.azure.com](https://shell.azure.com) (bash) and run:

```bash
curl -fsSL https://raw.githubusercontent.com/hailbytes/hailbytes-terraform-modules/main/quickstart/azure-ha/cloudshell.sh | bash
```

The script detects your egress IP for admin-UI allow-listing, generates an SSH key if you don't have one, writes `terraform.tfvars`, and runs `terraform init && terraform apply`. You review and confirm the plan before anything is created. Override defaults with `HB_CUSTOMER` (one deployment per client), `HB_RESOURCE_GROUP`, `HB_LOCATION`, `HB_ALLOWED_CIDR`, `HB_SSH_KEY_FILE`.

## Step 2 (option B): your own workstation

Requires Terraform >= 1.5 and an authenticated Azure CLI (`az login`).

```bash
git clone https://github.com/hailbytes/hailbytes-terraform-modules
cd hailbytes-terraform-modules/quickstart/azure-ha
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: set allowed_cidrs and ssh_public_key
terraform init && terraform apply
```

## Step 3: Verify

```bash
# Health endpoint through the load balancer. SAT's path is /api/health --
# there is no /health, and curling it returns 404, which looks like a failed
# deployment when it is only a wrong URL.
curl -k https://$(terraform output -raw load_balancer_public_ip)/api/health

# Optional zone-failure drill: stop one VM, confirm the other keeps serving
az vm deallocate -g $(terraform output -raw resource_group_name) \
  -n $(terraform output -json vm_ids | jq -r '.[0] | split("/")[-1]')
```

The DB password is in Key Vault (`terraform output key_vault_uri`) under the secret name `hailbytes-db-password`.

## Tearing down

```bash
terraform plan -destroy -out destroy.tfplan   # read it: everything should be in one resource group
terraform apply destroy.tfplan
```

[Runbook Step 10](../../docs/AZURE_MSSP_RUNBOOK.md#step-10-tear-it-down-with-terraform)
covers exporting data first, lifting delete locks, keeping other deployments'
Marketplace terms intact, and what deliberately survives.

## Production notes

- **TLS:** the default load balancer passes TLS through to per-VM self-signed certificates, so browsers warn. For a trusted certificate (and optional WAF), set `enable_application_gateway = true` and supply a PFX bundle; see [TLS termination](../../modules/ha-hot-hot/azure/README.md#tls-termination).
- **Costs:** roughly $585/month infrastructure plus ~$700/month marketplace software fee at the default sizing. Full breakdown and the three deployment shapes side by side: [COST_SHAPES.md](../../COST_SHAPES.md).
- **Patching:** customer-initiated rolling image swaps with pre-patch backups and auto-rollback; see [PATCHING_AND_MIGRATION.md](../../docs/PATCHING_AND_MIGRATION.md).
- **Full input reference:** [modules/ha-hot-hot/azure](../../modules/ha-hot-hot/azure/README.md).
